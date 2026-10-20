# SPDX-License-Identifier: MPL-2.0

defmodule VeriSim.Hypatia.PatternQuery do
  @moduledoc """
  Cross-repo pattern analytics for the Hypatia pipeline.

  Provides query functions over ingested scan data to identify patterns
  that appear across multiple repositories, track severity distributions,
  and detect temporal trends (scan-to-scan drift).

  ## Query Functions

  - `pipeline_health/0` — Overall pipeline status and metrics
  - `cross_repo_patterns/1` — Patterns appearing in N+ repos
  - `severity_distribution/0` — Severity breakdown across all scans
  - `category_distribution/0` — Category breakdown across all scans
  - `temporal_trends/1` — How a repo's scan results change over time
  - `repos_by_severity/1` — Repos ranked by severity count
  - `weakness_hotspots/0` — Files with highest weakness density

  Every aggregate over findings reads the *latest* scan of each repo, so a
  repo rescanned on every CI run is counted once, not once per run.
  `temporal_trends/1` is the one view over the full scan history.
  """

  require Logger

  alias VeriSim.Hypatia.ScanIngester

  # ---------------------------------------------------------------------------
  # Pipeline Health
  # ---------------------------------------------------------------------------

  @doc """
  Returns overall pipeline health metrics.

  Example:
      %{
        total_scans: 289,
        total_weak_points: 3260,
        repos_scanned: 289,
        severity_distribution: %{"High" => 120, "Medium" => 2800, "Low" => 340},
        top_categories: [{"PanicPath", 1200}, {"UnsafeCode", 500}, ...]
      }
  """
  def pipeline_health do
    scans = ScanIngester.list_scans()
    current = latest_per_repo(scans)

    all_weak_points = extract_all_weak_points(current)

    %{
      total_scans: length(scans),
      total_weak_points: length(all_weak_points),
      repos_scanned: length(current),
      severity_distribution: severity_distribution(all_weak_points),
      top_categories: top_categories(all_weak_points, 10),
      average_weak_points_per_repo: safe_avg(length(all_weak_points), length(current)),
      last_scan_timestamp: latest_timestamp(scans)
    }
  end

  # ---------------------------------------------------------------------------
  # Cross-Repo Patterns
  # ---------------------------------------------------------------------------

  @doc """
  Finds weakness patterns that appear across `min_repos` or more repositories.

  Returns a list of `{pattern_key, repo_count, repos}` tuples, sorted by
  repo count descending.

  The pattern key is `"category:severity"` (e.g., `"PanicPath:Medium"`).
  """
  def cross_repo_patterns(min_repos \\ 3) do
    # Build pattern → [repo_names] map
    pattern_repos =
      current_scans()
      |> extract_all_weak_points()
      |> Enum.map(fn wp ->
        {"#{wp["category"]}:#{wp["severity"]}", {wp["repo_key"], wp["repo"]}}
      end)
      |> Enum.group_by(fn {key, _} -> key end, fn {_, repo} -> repo end)
      # Count distinct repos by identity; report their display names.
      |> Map.new(fn {key, repos} ->
        {key, repos |> Enum.uniq_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))}
      end)

    pattern_repos
    |> Enum.filter(fn {_key, repos} -> length(repos) >= min_repos end)
    |> Enum.map(fn {key, repos} -> {key, length(repos), repos} end)
    |> Enum.sort_by(fn {_key, count, _repos} -> count end, :desc)
  end

  # ---------------------------------------------------------------------------
  # Severity Distribution
  # ---------------------------------------------------------------------------

  @doc """
  Returns a map of severity level → count across all scans.
  """
  def severity_distribution do
    current_scans()
    |> extract_all_weak_points()
    |> severity_distribution()
  end

  defp severity_distribution(weak_points) do
    weak_points
    |> Enum.frequencies_by(& &1["severity"])
  end

  # ---------------------------------------------------------------------------
  # Category Distribution
  # ---------------------------------------------------------------------------

  @doc """
  Returns a map of category → count across all scans, sorted by count descending.
  """
  def category_distribution do
    current_scans()
    |> extract_all_weak_points()
    |> Enum.frequencies_by(& &1["category"])
    |> Enum.sort_by(fn {_cat, count} -> count end, :desc)
  end

  # ---------------------------------------------------------------------------
  # Temporal Trends
  # ---------------------------------------------------------------------------

  @doc """
  Returns scan results for a specific repo over time, enabling drift detection.

  Each entry contains the scan timestamp and weak point count, sorted
  chronologically.
  """
  def temporal_trends(repo_name) when is_binary(repo_name) do
    ScanIngester.list_scans()
    |> Enum.filter(fn scan ->
      get_in(scan, [:metadata, :repo_name]) == repo_name
    end)
    # ingest_seq breaks same-second ties; ETS returns entries in hash order.
    |> Enum.sort_by(&{get_in(&1, [:metadata, :scan_timestamp]), &1[:ingest_seq] || 0})
    |> Enum.map(fn scan ->
      %{
        octad_id: scan[:octad_id],
        timestamp: get_in(scan, [:metadata, :scan_timestamp]),
        weak_point_count: get_in(scan, [:metadata, :weak_point_count]) || 0,
        severity_counts: get_in(scan, [:metadata, :severity_counts]) || %{}
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Repos by Severity
  # ---------------------------------------------------------------------------

  @doc """
  Returns repos ranked by total weakness count for a given severity level.

  Useful for identifying which repos need the most attention. Each repo
  appears once, counted from its latest scan.
  """
  def repos_by_severity(severity \\ "High") do
    current_scans()
    |> Enum.map(fn scan ->
      repo = get_in(scan, [:metadata, :repo_name]) || "unknown"
      counts = get_in(scan, [:metadata, :severity_counts]) || %{}
      count = counts[severity] || 0
      {repo, count}
    end)
    |> Enum.filter(fn {_repo, count} -> count > 0 end)
    |> Enum.sort_by(fn {_repo, count} -> count end, :desc)
  end

  # ---------------------------------------------------------------------------
  # Weakness Hotspots
  # ---------------------------------------------------------------------------

  @doc """
  Returns files ranked by weakness density across all repos.

  Identifies the most problematic files in the entire ecosystem. Keys are
  `{repo, location}`: the same relative path in two repos is two files.
  Findings are grouped by repo identity (the full program path), so two
  distinct repos that share a basename are two entries with the same name.
  """
  def weakness_hotspots do
    current_scans()
    |> extract_all_weak_points()
    |> Enum.group_by(&{&1["repo_key"], &1["location"] || "unknown"})
    |> Enum.map(fn {{_key, location}, [first | _] = items} ->
      {{first["repo"], location},
       %{count: length(items), categories: Enum.map(items, & &1["category"]) |> Enum.uniq()}}
    end)
    |> Enum.sort_by(fn {_loc, data} -> data.count end, :desc)
    |> Enum.take(50)
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp current_scans, do: latest_per_repo(ScanIngester.list_scans())

  # One scan per repo: the most recently ingested (highest ingest_seq).
  # Repos are identified by repo_key (the full program path); repo_name is the
  # basename, for display only, and two distinct repos can share it.
  defp latest_per_repo(scans) do
    scans
    |> Enum.group_by(&repo_key/1)
    |> Enum.map(fn {_repo, repo_scans} -> Enum.max_by(repo_scans, &(&1[:ingest_seq] || 0)) end)
  end

  # Returns the structured findings from the local scan index, or an empty list
  # when findings are missing or are not a list. Each finding is tagged with
  # its repo, and a missing category/severity becomes "unknown" here, so the
  # aggregators never see both nil and "unknown" as separate keys.
  defp extract_weak_points(%{weak_points: wps} = scan) when is_list(wps) do
    repo = get_in(scan, [:metadata, :repo_name]) || "unknown"
    key = repo_key(scan)

    Enum.map(wps, fn wp ->
      Map.merge(wp, %{
        "repo" => repo,
        "repo_key" => key,
        "category" => wp["category"] || "unknown",
        "severity" => wp["severity"] || "unknown"
      })
    end)
  end

  defp extract_weak_points(_scan), do: []

  defp repo_key(scan),
    do: scan[:repo_key] || get_in(scan, [:metadata, :repo_name]) || "unknown"

  defp extract_all_weak_points(scans) do
    Enum.flat_map(scans, &extract_weak_points/1)
  end

  defp top_categories(weak_points, limit) do
    weak_points
    |> Enum.frequencies_by(& &1["category"])
    |> Enum.sort_by(fn {_cat, count} -> count end, :desc)
    |> Enum.take(limit)
  end

  defp safe_avg(_total, 0), do: 0.0
  defp safe_avg(total, count), do: Float.round(total / count, 1)

  defp latest_timestamp(scans) do
    scans
    |> Enum.map(&get_in(&1, [:metadata, :scan_timestamp]))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort(:desc)
    |> List.first()
  end
end
