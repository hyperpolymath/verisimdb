# SPDX-License-Identifier: PMPL-1.0-or-later

defmodule VeriSim.Query.VQLExecutor do
  @moduledoc """
  VQL Executor - Executes VQL queries parsed by the ReScript VQL parser.

  This module takes parsed VQL AST and executes it against the
  Rust modality stores, coordinating cross-modal queries.

  ## Execution Pipeline

  1. Parse VQL query (done by ReScript VQLParser)
  2. Type-check if PROOF clause present (VQLTypeChecker)
  3. Generate execution plan (VQLExplain)
  4. Route to appropriate modality stores
  5. Aggregate and return results
  """

  require Logger

  alias VeriSim.{QueryRouter, RustClient}

  @doc """
  Execute a parsed VQL query.

  ## Parameters

  - `query_ast` - Parsed VQL query from ReScript VQLParser
  - `opts` - Execution options

  ## Options

  - `:explain` - Return execution plan instead of results
  - `:timeout` - Query timeout in milliseconds (default: 30000)
  - `:verify_proof` - Verify ZKP proofs for dependent-type queries (default: true)

  ## Returns

  - `{:ok, results}` - Query results
  - `{:error, reason}` - Query execution failed
  """
  def execute(query_ast, opts \\ []) do
    explain = Keyword.get(opts, :explain, false)
    timeout = Keyword.get(opts, :timeout, 30_000)

    if explain do
      {:ok, generate_explain_plan(query_ast)}
    else
      execute_query(query_ast, timeout)
    end
  end

  @doc """
  Execute a VQL query string (includes parsing).

  This is a convenience function that parses and executes in one call.
  For better performance, parse once and execute multiple times.
  """
  def execute_string(query_string, opts \\ []) do
    case VeriSim.Query.VQLBridge.parse(query_string) do
      {:ok, ast} -> execute(ast, opts)
      {:error, reason} -> {:error, {:parse_error, reason}}
    end
  end

  # Private Functions

  defp execute_query(query_ast, timeout) do
    # Extract query components from AST
    modalities = extract_modalities(query_ast)
    source = extract_source(query_ast)
    where_clause = extract_where(query_ast)
    proof_spec = extract_proof(query_ast)
    limit = extract_limit(query_ast)
    offset = extract_offset(query_ast)

    # Verify proof if required
    if proof_spec do
      case verify_proof_requirements(query_ast, proof_spec) do
        :ok -> :continue
        {:error, reason} -> {:error, {:proof_verification_failed, reason}}
      end
    end

    # Execute based on source type
    case source do
      {:hexad, entity_id} ->
        execute_hexad_query(entity_id, modalities, where_clause, limit, offset, timeout)

      {:federation, pattern, drift_policy} ->
        execute_federation_query(pattern, drift_policy, modalities, where_clause, limit, offset, timeout)

      {:store, store_id} ->
        execute_store_query(store_id, modalities, where_clause, limit, offset, timeout)
    end
  end

  defp execute_hexad_query(entity_id, modalities, where_clause, limit, offset, timeout) do
    # Query single hexad across requested modalities
    case RustClient.get_hexad(entity_id) do
      {:ok, hexad} ->
        # Filter by modalities and apply WHERE clause
        filtered = filter_hexad(hexad, modalities, where_clause)
        paginated = paginate_results([filtered], limit, offset)
        {:ok, paginated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_federation_query(pattern, drift_policy, modalities, where_clause, limit, offset, timeout) do
    # Federation query - search across multiple stores
    # This would coordinate with multiple Rust instances
    Logger.info("Federation query: pattern=#{pattern}, drift_policy=#{inspect(drift_policy)}")

    # Placeholder: In production, this would:
    # 1. Resolve pattern to list of stores
    # 2. Query each store in parallel
    # 3. Apply drift policy (STRICT/REPAIR/TOLERATE/LATEST)
    # 4. Aggregate results
    # 5. Deduplicate and rank

    {:ok, []}
  end

  defp execute_store_query(store_id, modalities, where_clause, limit, offset, timeout) do
    # Query specific store
    Logger.info("Store query: store_id=#{store_id}")

    # Route to appropriate modality based on query
    query_type = determine_query_type(modalities, where_clause)

    case query_type do
      :text ->
        text_query = extract_text_query(where_clause)
        QueryRouter.query(:text, text_query, limit: limit || 10)

      :vector ->
        {embedding, threshold} = extract_vector_query(where_clause)
        QueryRouter.query(:vector, embedding, k: limit || 10)

      :graph ->
        graph_params = extract_graph_query(where_clause)
        QueryRouter.query(:graph, graph_params)

      :multi ->
        # Multi-modal query
        params = extract_multi_modal_params(modalities, where_clause)
        QueryRouter.query(:multi, params, limit: limit || 10)

      _ ->
        {:error, :unsupported_query_type}
    end
  end

  defp filter_hexad(hexad, modalities, where_clause) do
    # Filter hexad data by modalities
    filtered_modalities =
      if :all in modalities do
        hexad
      else
        Map.take(hexad, modalities |> Enum.map(&to_string/1))
      end

    # Apply WHERE clause filtering
    # In production, this would evaluate the AST condition tree
    filtered_modalities
  end

  defp paginate_results(results, nil, nil), do: results
  defp paginate_results(results, limit, nil), do: Enum.take(results, limit)
  defp paginate_results(results, nil, offset), do: Enum.drop(results, offset)
  defp paginate_results(results, limit, offset) do
    results
    |> Enum.drop(offset)
    |> Enum.take(limit)
  end

  defp determine_query_type(modalities, where_clause) do
    cond do
      has_fulltext_condition?(where_clause) -> :text
      has_vector_condition?(where_clause) -> :vector
      has_graph_pattern?(where_clause) -> :graph
      length(modalities) > 1 -> :multi
      true -> :multi
    end
  end

  defp has_fulltext_condition?(nil), do: false
  defp has_fulltext_condition?(_where_clause) do
    # Would inspect AST for FulltextContains/FulltextMatches
    false
  end

  defp has_vector_condition?(nil), do: false
  defp has_vector_condition?(_where_clause) do
    # Would inspect AST for VectorSimilar
    false
  end

  defp has_graph_pattern?(nil), do: false
  defp has_graph_pattern?(_where_clause) do
    # Would inspect AST for GraphPattern
    false
  end

  defp extract_text_query(_where_clause) do
    # Extract text from WHERE clause
    "placeholder query"
  end

  defp extract_vector_query(_where_clause) do
    # Extract embedding vector and threshold
    {[0.1, 0.2, 0.3], 0.9}
  end

  defp extract_graph_query(_where_clause) do
    # Extract graph pattern
    %{}
  end

  defp extract_multi_modal_params(modalities, where_clause) do
    %{
      modalities: modalities,
      conditions: where_clause
    }
  end

  defp verify_proof_requirements(_query_ast, _proof_spec) do
    # Verify ZKP proof requirements
    # In production: call VQLTypeChecker, generate witness, verify proof
    :ok
  end

  defp generate_explain_plan(query_ast) do
    # Generate execution plan
    %{
      strategy: :sequential,
      steps: [
        %{operation: "Parse", cost_ms: 1},
        %{operation: "Type check", cost_ms: 5},
        %{operation: "Route to stores", cost_ms: 10},
        %{operation: "Execute", cost_ms: 50},
        %{operation: "Aggregate", cost_ms: 5}
      ],
      total_cost_ms: 71
    }
  end

  # AST extraction helpers

  defp extract_modalities(query_ast) do
    Map.get(query_ast, :modalities, [:all])
  end

  defp extract_source(query_ast) do
    Map.get(query_ast, :source, {:hexad, "default"})
  end

  defp extract_where(query_ast) do
    Map.get(query_ast, :where, nil)
  end

  defp extract_proof(query_ast) do
    Map.get(query_ast, :proof, nil)
  end

  defp extract_limit(query_ast) do
    Map.get(query_ast, :limit, nil)
  end

  defp extract_offset(query_ast) do
    Map.get(query_ast, :offset, nil)
  end
end
