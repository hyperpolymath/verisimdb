# SPDX-License-Identifier: MPL-2.0

defmodule VeriSim.Hypatia.ScanIngester do
  @moduledoc """
  Ingests panic-attack scan results and stores them as VeriSimDB octad entities.

  Each scan report becomes an octad entity with:
  - **Document**: Full JSON report as searchable text
  - **Graph**: file → weakness → recommendation triples
  - **Temporal**: Scan timestamp (enables drift tracking across cycles)
  - **Vector**: Weakness description embeddings (for similarity search)
  - **Provenance**: Scanner identity, CI run origin, transformation chain
  - **Semantic**: Severity annotations, category tags

  ## Data Flow

      panic-attack assail (JSON)
              │
      ScanIngester.ingest_scan/1
              │
      ┌───────┴───────┐
      │  Octad Entity  │  ← Document, Graph, Temporal, Vector, Provenance, Semantic
      └───────┬───────┘
              │
      VeriSimDB storage
              │
      Hypatia VCL queries

  ## Usage

      # Ingest a single scan result
      {:ok, octad_id} = ScanIngester.ingest_scan(scan_json)

      # Ingest all scans from verisimdb-data/scans/ directory
      {:ok, results} = ScanIngester.ingest_directory("/path/to/verisimdb-data/scans")

      # Ingest from a panic-attack JSON file
      {:ok, octad_id} = ScanIngester.ingest_file("/path/to/scan.json")
  """

  require Logger

  alias VeriSim.RustClient

  @type scan_report :: %{
          optional(String.t()) => any()
        }

  @type weak_point :: %{
          optional(String.t()) => any()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Ingest a panic-attack scan result (decoded JSON map) into VeriSimDB.

  The scan report is expected to have an `assail_report` key containing:
  - `program_path` — path to the scanned repository
  - `language` — detected primary language
  - `frameworks` — detected frameworks
  - `weak_points` — list of weakness findings

  Returns `{:ok, octad_id}` or `{:error, reason}`.
  """
  def ingest_scan(scan_report) when is_map(scan_report) do
    report = scan_report["assail_report"] || scan_report

    repo_name = extract_repo_name(report["program_path"])
    octad_id = "scan:#{repo_name}:#{timestamp_id()}"

    octad_input = build_octad(octad_id, repo_name, report)

    # Always index locally: PatternQuery reads only this table, so a scan the
    # Rust core accepted must land here too, or it is invisible to analytics.
    # The index keeps the structured findings beside the octad; the document
    # body is prose for full-text search and cannot be parsed back into them.
    # ingest_seq orders a repo's scans so PatternQuery can pick the latest.
    # repo_key is the repo's identity: the full program path, because the
    # basename in repo_name is display-only and collides across orgs and
    # monorepo subdirectories (/org-a/api vs /org-b/api).
    store_local(
      octad_id,
      Map.merge(octad_input, %{
        weak_points: report["weak_points"] || [],
        ingest_seq: System.unique_integer([:positive, :monotonic]),
        repo_key: report["program_path"] || repo_name
      })
    )

    case RustClient.create_octad(octad_input) do
      {:ok, _result} ->
        Logger.info("Hypatia: ingested scan for #{repo_name} as #{octad_id}")
        {:ok, octad_id}

      {:error, reason} ->
        Logger.warning(
          "Hypatia: failed to ingest scan for #{repo_name} via Rust core, " <>
            "kept in the local index only: #{inspect(reason)}"
        )

        {:ok, octad_id}
    end
  end

  def ingest_scan(_), do: {:error, :invalid_scan_format}

  @doc """
  Ingest a scan result from a JSON file on disk.

  Returns `{:ok, octad_id}` or `{:error, reason}`.
  """
  def ingest_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, scan} -> ingest_scan(scan)
          {:error, reason} -> {:error, {:json_parse_error, reason}}
        end

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  @doc """
  Ingest all scan JSON files from a directory.

  Returns `{:ok, results}` where results is a list of
  `{filename, {:ok, octad_id}}` or `{filename, {:error, reason}}`.
  """
  def ingest_directory(dir_path) when is_binary(dir_path) do
    case File.ls(dir_path) do
      {:ok, files} ->
        # Oldest file first: reports carry no timestamp of their own, and
        # ingest order decides which scan of a repo counts as its latest.
        results =
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.sort_by(fn file ->
            {file_mtime(Path.join(dir_path, file)), file}
          end)
          |> Enum.map(fn file ->
            path = Path.join(dir_path, file)
            {file, ingest_file(path)}
          end)

        successful = Enum.count(results, fn {_, result} -> match?({:ok, _}, result) end)

        Logger.info(
          "Hypatia: ingested #{successful}/#{length(results)} scan files from #{dir_path}"
        )

        {:ok, results}

      {:error, reason} ->
        {:error, {:dir_read_error, reason}}
    end
  end

  @doc """
  Query all ingested scans. Returns locally stored scans when Rust core is unavailable.
  """
  def list_scans do
    ensure_ets_table()

    :ets.tab2list(:hypatia_scans)
    |> Enum.map(fn {id, data} -> Map.put(data, :octad_id, id) end)
  end

  @doc """
  Get the latest scan for a repo, given its full program path or its
  basename. A basename shared by two repos matches both; pass the path to
  pick one.
  """
  def get_scan(repo) when is_binary(repo) do
    ensure_ets_table()

    # The latest scan, not whichever one ETS happens to return first.
    :ets.tab2list(:hypatia_scans)
    |> Enum.filter(fn {_id, data} -> matches_repo?(data, repo) end)
    |> Enum.max_by(fn {_id, data} -> data[:ingest_seq] || 0 end, fn -> nil end)
    |> case do
      {id, data} -> {:ok, Map.put(data, :octad_id, id)}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  True when an index entry belongs to `repo`, given as the repo's full
  program path (its identity) or its basename (display name).
  """
  def matches_repo?(entry, repo) do
    entry[:repo_key] == repo or get_in(entry, [:metadata, :repo_name]) == repo
  end

  # ---------------------------------------------------------------------------
  # Private: Octad Construction
  # ---------------------------------------------------------------------------

  defp build_octad(octad_id, repo_name, report) do
    weak_points = report["weak_points"] || []
    language = report["language"] || "unknown"
    frameworks = report["frameworks"] || []

    %{
      octad_id: octad_id,
      metadata: %{
        repo_name: repo_name,
        language: language,
        frameworks: frameworks,
        scan_timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        weak_point_count: length(weak_points),
        severity_counts: count_severities(weak_points)
      },

      # Document modality: full report as searchable text
      document: %{
        title: "Panic-attack scan: #{repo_name}",
        body: build_document_body(repo_name, language, weak_points),
        content_type: "application/json"
      },

      # Graph modality: file → weakness → recommendation triples
      graph: %{
        triples: build_graph_triples(octad_id, repo_name, weak_points)
      },

      # Temporal modality: scan timestamp for drift tracking
      temporal: %{
        timestamp: System.system_time(:millisecond),
        version: "scan-v1",
        event_type: "panic_attack_scan"
      },

      # Provenance modality: scanner and origin tracking
      provenance: %{
        source: "panic-attack",
        actor: "hypatia-scan-workflow",
        operation: "assail",
        input_path: report["program_path"]
      },

      # Semantic modality: type annotations and severity tags
      semantic: %{
        types: ["scan_result", "security_finding", "panic_attack_report"],
        tags: extract_categories(weak_points),
        severity_levels: Enum.map(weak_points, & &1["severity"]) |> Enum.uniq()
      },

      # Vector modality: embedding from weakness descriptions
      vector: %{
        text_for_embedding: build_embedding_text(weak_points),
        dimensions: nil
      }
    }
  end

  defp build_document_body(repo_name, language, weak_points) do
    weakness_text =
      weak_points
      |> Enum.map(fn wp ->
        "#{wp["severity"]} #{wp["category"]} in #{wp["location"]}: #{wp["description"]}"
      end)
      |> Enum.join("\n")

    """
    Repository: #{repo_name}
    Language: #{language}
    Weak Points: #{length(weak_points)}

    #{weakness_text}
    """
  end

  defp build_graph_triples(octad_id, repo_name, weak_points) do
    repo_node = "repo:#{repo_name}"

    # repo → has_scan → scan (lists for JSON compatibility)
    base = [[repo_node, "has_scan", octad_id]]

    # For each weak point: scan → has_weakness → weakness, weakness → in_file → file
    weakness_triples =
      weak_points
      |> Enum.with_index()
      |> Enum.flat_map(fn {wp, idx} ->
        weakness_id = "#{octad_id}:wp:#{idx}"
        file = wp["location"] || "unknown"
        category = wp["category"] || "unknown"

        [
          [octad_id, "has_weakness", weakness_id],
          [weakness_id, "in_file", "file:#{file}"],
          [weakness_id, "has_category", "category:#{category}"],
          [weakness_id, "has_severity", "severity:#{wp["severity"] || "unknown"}"]
        ]
      end)

    base ++ weakness_triples
  end

  defp build_embedding_text(weak_points) do
    weak_points
    |> Enum.map(fn wp ->
      "#{wp["category"]} #{wp["severity"]} #{wp["description"]}"
    end)
    |> Enum.join(" ")
    |> String.slice(0, 2000)
  end

  defp extract_categories(weak_points) do
    weak_points
    |> Enum.map(& &1["category"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp count_severities(weak_points) do
    weak_points
    |> Enum.group_by(& &1["severity"])
    |> Map.new(fn {severity, items} -> {severity, length(items)} end)
  end

  # ---------------------------------------------------------------------------
  # Private: Helpers
  # ---------------------------------------------------------------------------

  defp extract_repo_name(nil), do: "unknown"

  defp extract_repo_name(path) when is_binary(path) do
    path
    |> String.split("/")
    |> List.last()
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "")
  end

  # Second resolution alone collides when one repo is ingested twice in the
  # same second (e.g. ingest_directory/1 over historical scans), and the later
  # scan would silently replace the earlier one. The monotonic suffix keeps
  # ids unique within the node and still ordered by time.
  defp timestamp_id do
    stamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601(:basic)
      |> String.replace(~r/[^0-9]/, "")
      |> String.slice(0, 14)

    "#{stamp}-#{System.unique_integer([:positive, :monotonic])}"
  end

  # ---------------------------------------------------------------------------
  # Private: Local ETS scan index (read by PatternQuery; written on every ingest)
  # ---------------------------------------------------------------------------

  @doc """
  Create the local scan index. Called from `VeriSim.Application.start/2` so the
  table is owned by the application master and lives as long as the app; an
  ETS table created lazily would die with whichever process first touched it.
  """
  def init_table, do: ensure_ets_table()

  # Ensures the public, named scan index exists, tolerating concurrent creation.
  # Returns :ok whether the table already existed or was just created.
  defp ensure_ets_table do
    case :ets.info(:hypatia_scans) do
      :undefined ->
        :ets.new(:hypatia_scans, [:named_table, :set, :public])
        :ok

      _ ->
        :ok
    end
  rescue
    # Another process created the table between the info check and new/2.
    ArgumentError -> :ok
  end

  defp store_local(octad_id, octad_input) do
    ensure_ets_table()
    :ets.insert(:hypatia_scans, {octad_id, octad_input})
    prune_history(octad_input[:repo_key])
    :ok
  end

  # Keep the newest `:hypatia_scan_history` scans per repo (default 50), so a
  # long-lived node rescanning on every CI run does not grow without bound.
  defp prune_history(repo_key) do
    limit = Application.get_env(:verisim, :hypatia_scan_history, 50)

    # Fetch only this repo's {id, ingest_seq} pairs, not the whole table.
    :ets.select(:hypatia_scans, [
      {{:"$1", %{repo_key: :"$2", ingest_seq: :"$3"}}, [{:==, :"$2", {:const, repo_key}}],
       [{{:"$1", :"$3"}}]}
    ])
    |> Enum.sort_by(fn {_id, seq} -> seq end, :desc)
    |> Enum.drop(limit)
    |> Enum.each(fn {id, _seq} -> :ets.delete(:hypatia_scans, id) end)
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _} -> 0
    end
  end
end
