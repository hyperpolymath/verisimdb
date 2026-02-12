# SPDX-License-Identifier: PMPL-1.0-or-later

defmodule VeriSim.Query.VQLBridge do
  @moduledoc """
  Bridge between the ReScript VQL parser and Elixir VQL executor.

  Manages a long-running Deno/Node process that runs the compiled ReScript
  VQL parser. Communication uses JSON over stdin/stdout with length-prefixed
  framing for reliable message boundaries.

  ## Architecture

      VQL String ──► VQLBridge (GenServer)
                        │
                        ▼
                     Port (stdin/stdout JSON)
                        │
                        ▼
                     Deno process running compiled VQLParser.res
                        │
                        ▼
                     Parsed AST (JSON) ──► VQLExecutor

  ## Usage

      {:ok, ast} = VQLBridge.parse("SELECT GRAPH, VECTOR FROM HEXAD abc-123")
      {:ok, results} = VQLExecutor.execute(ast)
  """

  use GenServer
  require Logger

  @default_timeout 5_000
  @parser_script_path "vql-bridge/vql_parser_port.js"

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Parse a VQL query string into an AST map.

  Returns `{:ok, ast}` where ast is a map matching the VQLParser.AST types,
  or `{:error, reason}` on parse failure.
  """
  def parse(query_string, timeout \\ @default_timeout) do
    GenServer.call(__MODULE__, {:parse, query_string}, timeout)
  end

  @doc """
  Parse a slipstream query (no PROOF clause allowed).
  """
  def parse_slipstream(query_string, timeout \\ @default_timeout) do
    GenServer.call(__MODULE__, {:parse_slipstream, query_string}, timeout)
  end

  @doc """
  Parse a dependent-type query (PROOF clause required).
  """
  def parse_dependent(query_string, timeout \\ @default_timeout) do
    GenServer.call(__MODULE__, {:parse_dependent, query_string}, timeout)
  end

  @doc """
  Parse and execute a VQL query string in one call.
  Combines VQLBridge.parse/1 with VQLExecutor.execute/2.
  """
  def parse_and_execute(query_string, opts \\ []) do
    case parse(query_string) do
      {:ok, ast} -> VeriSim.Query.VQLExecutor.execute(ast, opts)
      {:error, _} = error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    runtime = Keyword.get(opts, :runtime, detect_runtime())
    script_path = Keyword.get(opts, :script_path, resolve_script_path())

    state = %{
      port: nil,
      runtime: runtime,
      script_path: script_path,
      pending: %{},
      next_id: 1
    }

    case start_port(state) do
      {:ok, port} ->
        Logger.info("VQLBridge started with #{runtime}")
        {:ok, %{state | port: port}}

      {:error, reason} ->
        Logger.warning("VQLBridge: parser process unavailable (#{reason}), falling back to built-in parser")
        {:ok, state}
    end
  end

  @impl true
  def handle_call({action, query_string}, from, %{port: nil} = state)
      when action in [:parse, :parse_slipstream, :parse_dependent] do
    # Fallback: no external parser available, use built-in Elixir parser
    result = builtin_parse(query_string, action)
    {:reply, result, state}
  end

  @impl true
  def handle_call({action, query_string}, from, state)
      when action in [:parse, :parse_slipstream, :parse_dependent] do
    id = state.next_id
    message = Jason.encode!(%{
      "id" => id,
      "action" => Atom.to_string(action),
      "query" => query_string
    })

    # Send length-prefixed message to port
    send_to_port(state.port, message)

    pending = Map.put(state.pending, id, from)
    {:noreply, %{state | pending: pending, next_id: id + 1}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Jason.decode(IO.iodata_to_binary(data)) do
      {:ok, %{"id" => id, "ok" => ast}} ->
        case Map.pop(state.pending, id) do
          {nil, _} -> {:noreply, state}
          {from, pending} ->
            GenServer.reply(from, {:ok, atomize_keys(ast)})
            {:noreply, %{state | pending: pending}}
        end

      {:ok, %{"id" => id, "error" => reason}} ->
        case Map.pop(state.pending, id) do
          {nil, _} -> {:noreply, state}
          {from, pending} ->
            GenServer.reply(from, {:error, reason})
            {:noreply, %{state | pending: pending}}
        end

      {:error, _} ->
        Logger.warning("VQLBridge: received malformed data from parser port")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("VQLBridge: parser process exited with status #{status}")

    # Reply to all pending requests with error
    for {_id, from} <- state.pending do
      GenServer.reply(from, {:error, :parser_crashed})
    end

    # Try to restart
    case start_port(state) do
      {:ok, new_port} ->
        Logger.info("VQLBridge: parser process restarted")
        {:noreply, %{state | port: new_port, pending: %{}}}

      {:error, _} ->
        {:noreply, %{state | port: nil, pending: %{}}}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp start_port(state) do
    runtime = state.runtime
    script = state.script_path

    if runtime && File.exists?(script) do
      try do
        port = Port.open(
          {:spawn_executable, runtime},
          [:binary, :exit_status, {:args, [script]}, {:line, 1_048_576}]
        )
        {:ok, port}
      rescue
        e -> {:error, Exception.message(e)}
      end
    else
      {:error, "runtime (#{runtime}) or script (#{script}) not found"}
    end
  end

  defp send_to_port(port, message) do
    Port.command(port, message <> "\n")
  end

  defp detect_runtime do
    cond do
      System.find_executable("deno") -> System.find_executable("deno")
      System.find_executable("node") -> System.find_executable("node")
      true -> nil
    end
  end

  defp resolve_script_path do
    # Look relative to the project root
    base = Application.get_env(:verisim, :project_root, File.cwd!())
    Path.join(base, @parser_script_path)
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        {String.to_existing_atom(key), atomize_keys(value)}
      {key, value} ->
        {key, atomize_keys(value)}
    end)
  rescue
    ArgumentError -> map
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(other), do: other

  # ---------------------------------------------------------------------------
  # Built-in Elixir Parser (fallback when Deno/Node unavailable)
  # ---------------------------------------------------------------------------

  defp builtin_parse(query_string, action) do
    query_string = String.trim(query_string)

    with {:ok, tokens} <- tokenize(query_string),
         {:ok, ast} <- parse_tokens(tokens) do
      case action do
        :parse_slipstream ->
          if ast[:proof], do: {:error, "Slipstream queries cannot have PROOF clause"}, else: {:ok, ast}
        :parse_dependent ->
          if ast[:proof], do: {:ok, ast}, else: {:error, "Dependent-type queries require PROOF clause"}
        :parse ->
          {:ok, ast}
      end
    end
  end

  defp tokenize(input) do
    # Simple whitespace-aware tokenizer
    tokens =
      input
      |> String.replace(~r/\s+/, " ")
      |> String.split(" ", trim: true)

    {:ok, tokens}
  end

  defp parse_tokens(tokens) do
    with {:ok, modalities, rest} <- parse_select(tokens),
         {:ok, source, rest} <- parse_from(rest),
         {:ok, where_clause, rest} <- parse_where(rest),
         {:ok, proof, rest} <- parse_proof(rest),
         {:ok, limit, rest} <- parse_limit(rest),
         {:ok, offset, _rest} <- parse_offset(rest) do
      {:ok, %{
        modalities: modalities,
        source: source,
        where: where_clause,
        proof: proof,
        limit: limit,
        offset: offset
      }}
    end
  end

  defp parse_select(["SELECT" | rest]) do
    {modalities, rest} = take_modalities(rest, [])
    {:ok, modalities, rest}
  end

  defp parse_select(_), do: {:error, "Expected SELECT"}

  defp take_modalities(["GRAPH" | rest], acc), do: take_modalities(strip_comma(rest), [:graph | acc])
  defp take_modalities(["VECTOR" | rest], acc), do: take_modalities(strip_comma(rest), [:vector | acc])
  defp take_modalities(["TENSOR" | rest], acc), do: take_modalities(strip_comma(rest), [:tensor | acc])
  defp take_modalities(["SEMANTIC" | rest], acc), do: take_modalities(strip_comma(rest), [:semantic | acc])
  defp take_modalities(["DOCUMENT" | rest], acc), do: take_modalities(strip_comma(rest), [:document | acc])
  defp take_modalities(["TEMPORAL" | rest], acc), do: take_modalities(strip_comma(rest), [:temporal | acc])
  defp take_modalities(["*" | rest], acc), do: take_modalities(strip_comma(rest), [:all | acc])
  defp take_modalities(rest, acc), do: {Enum.reverse(acc), rest}

  defp strip_comma(["," <> token | rest]) when token != "" do
    [token | rest]
  end
  defp strip_comma(["," | rest]), do: rest
  defp strip_comma(rest), do: rest

  defp parse_from(["FROM", "HEXAD", uuid | rest]) do
    {:ok, {:hexad, uuid}, rest}
  end

  defp parse_from(["FROM", "FEDERATION", pattern | rest]) do
    {drift_policy, rest} = parse_drift_policy(rest)
    {:ok, {:federation, pattern, drift_policy}, rest}
  end

  defp parse_from(["FROM", "STORE", store_id | rest]) do
    {:ok, {:store, store_id}, rest}
  end

  defp parse_from(_), do: {:error, "Expected FROM clause"}

  defp parse_drift_policy(["WITH", "DRIFT", policy | rest]) do
    drift = case String.upcase(policy) do
      "STRICT" -> :strict
      "REPAIR" -> :repair
      "TOLERATE" -> :tolerate
      "LATEST" -> :latest
      _ -> nil
    end
    {drift, rest}
  end

  defp parse_drift_policy(rest), do: {nil, rest}

  defp parse_where(["WHERE" | rest]) do
    # Simplified: collect everything until PROOF, LIMIT, OFFSET, or end
    {condition_tokens, rest} = Enum.split_while(rest, fn token ->
      token not in ["PROOF", "LIMIT", "OFFSET"]
    end)

    condition = if condition_tokens == [] do
      nil
    else
      %{raw: Enum.join(condition_tokens, " ")}
    end

    {:ok, condition, rest}
  end

  defp parse_where(rest), do: {:ok, nil, rest}

  defp parse_proof(["PROOF" | rest]) do
    {proof_tokens, rest} = Enum.split_while(rest, fn token ->
      token not in ["LIMIT", "OFFSET"]
    end)
    {:ok, %{raw: Enum.join(proof_tokens, " ")}, rest}
  end

  defp parse_proof(rest), do: {:ok, nil, rest}

  defp parse_limit(["LIMIT", n | rest]) do
    case Integer.parse(n) do
      {limit, _} -> {:ok, limit, rest}
      :error -> {:error, "Invalid LIMIT value"}
    end
  end

  defp parse_limit(rest), do: {:ok, nil, rest}

  defp parse_offset(["OFFSET", n | rest]) do
    case Integer.parse(n) do
      {offset, _} -> {:ok, offset, rest}
      :error -> {:error, "Invalid OFFSET value"}
    end
  end

  defp parse_offset(rest), do: {:ok, nil, rest}
end
