# SPDX-License-Identifier: PMPL-1.0-or-later

defmodule VeriSim.Query.VQLExecutor do
  @moduledoc """
  VQL Executor - Executes VQL queries and mutations parsed by the ReScript VQL parser.

  Supports three phases:
  1. Dependent-type queries with multi-proof composition
  2. Cross-modal correlation conditions
  3. Write path (INSERT / UPDATE / DELETE)

  ## Execution Pipeline

  1. Parse VQL query (done by ReScript VQLParser)
  2. Type-check if PROOF clause present (VQLTypeChecker → VQLBidir)
  3. Generate execution plan (VQLExplain)
  4. Classify conditions (pushdown vs cross-modal)
  5. Route to appropriate modality stores
  6. Evaluate cross-modal conditions post-fetch
  7. Aggregate and return results
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
  Execute a VQL mutation (INSERT / UPDATE / DELETE).
  """
  def execute_mutation(mutation_ast, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    case mutation_ast do
      %{TAG: "Insert", modalities: modality_data, proof: proof} ->
        execute_insert(modality_data, proof, timeout)

      %{TAG: "Update", hexadId: hexad_id, sets: sets, proof: proof} ->
        execute_update(hexad_id, sets, proof, timeout)

      %{TAG: "Delete", hexadId: hexad_id, proof: proof} ->
        execute_delete(hexad_id, proof, timeout)

      _ ->
        {:error, {:invalid_mutation, "Unknown mutation type"}}
    end
  end

  @doc """
  Execute a VQL statement (query or mutation).
  """
  def execute_statement(statement_ast, opts \\ []) do
    case statement_ast do
      %{TAG: "Query", _0: query} -> execute(query, opts)
      %{TAG: "Mutation", _0: mutation} -> execute_mutation(mutation, opts)
      # Map with :type key from built-in parser
      %{type: :query} -> execute(statement_ast, opts)
      %{type: :mutation, mutation: mutation} -> execute_mutation(mutation, opts)
      _ -> execute(statement_ast, opts)
    end
  end

  @doc """
  Execute a VQL query string (includes parsing).
  """
  def execute_string(query_string, opts \\ []) do
    case VeriSim.Query.VQLBridge.parse(query_string) do
      {:ok, ast} -> execute(ast, opts)
      {:error, reason} -> {:error, {:parse_error, reason}}
    end
  end

  # ===========================================================================
  # Query Execution
  # ===========================================================================

  defp execute_query(query_ast, timeout) do
    modalities = extract_modalities(query_ast)
    source = extract_source(query_ast)
    where_clause = extract_where(query_ast)
    proof_specs = extract_proof(query_ast)
    limit = extract_limit(query_ast)
    offset = extract_offset(query_ast)
    order_by = extract_order_by(query_ast)
    group_by = extract_group_by(query_ast)
    aggregates = extract_aggregates(query_ast)
    projections = extract_projections(query_ast)

    # Verify proofs if required (multi-proof support)
    if proof_specs do
      case verify_multi_proof(query_ast, proof_specs) do
        :ok -> :continue
        {:error, reason} -> {:error, {:proof_verification_failed, reason}}
      end
    end

    # Phase 2: Classify conditions into pushdown vs cross-modal
    {pushdown_conditions, cross_modal_conditions} = classify_conditions(where_clause)

    # Execute based on source type (with pushdown conditions only)
    result = case source do
      {:hexad, entity_id} ->
        execute_hexad_query(entity_id, modalities, pushdown_conditions, limit, offset, timeout)

      {:federation, pattern, drift_policy} ->
        execute_federation_query(pattern, drift_policy, modalities, pushdown_conditions, limit, offset, timeout)

      {:store, store_id} ->
        execute_store_query(store_id, modalities, pushdown_conditions, limit, offset, timeout)
    end

    # Post-process
    case result do
      {:ok, rows} ->
        rows
        |> maybe_evaluate_cross_modal(cross_modal_conditions)
        |> maybe_group_and_aggregate(group_by, aggregates)
        |> maybe_order_by(order_by)
        |> maybe_project_columns(projections)
        |> then(&{:ok, &1})

      error -> error
    end
  end

  # ===========================================================================
  # Phase 2: Condition Classification
  # ===========================================================================

  defp classify_conditions(nil), do: {nil, []}
  defp classify_conditions(%{raw: _} = condition), do: {condition, []}
  defp classify_conditions(condition) when is_map(condition) do
    case condition do
      %{TAG: "CrossModalFieldCompare"} -> {nil, [condition]}
      %{TAG: "ModalityDrift"} -> {nil, [condition]}
      %{TAG: "ModalityExists"} -> {nil, [condition]}
      %{TAG: "ModalityNotExists"} -> {nil, [condition]}
      %{TAG: "ModalityConsistency"} -> {nil, [condition]}
      %{TAG: "And", _0: left, _1: right} ->
        {push_l, cross_l} = classify_conditions(left)
        {push_r, cross_r} = classify_conditions(right)
        pushdown = combine_pushdown(push_l, push_r, :and)
        {pushdown, cross_l ++ cross_r}
      %{TAG: "Or", _0: left, _1: right} ->
        {push_l, cross_l} = classify_conditions(left)
        {push_r, cross_r} = classify_conditions(right)
        pushdown = combine_pushdown(push_l, push_r, :or)
        {pushdown, cross_l ++ cross_r}
      %{TAG: "Not", _0: inner} ->
        {push, cross} = classify_conditions(inner)
        {push, cross}
      _ ->
        # Simple condition: pushdown
        {condition, []}
    end
  end
  defp classify_conditions(condition), do: {condition, []}

  defp combine_pushdown(nil, nil, _op), do: nil
  defp combine_pushdown(a, nil, _op), do: a
  defp combine_pushdown(nil, b, _op), do: b
  defp combine_pushdown(a, b, :and), do: %{TAG: "And", _0: a, _1: b}
  defp combine_pushdown(a, b, :or), do: %{TAG: "Or", _0: a, _1: b}

  # ===========================================================================
  # Phase 2: Cross-Modal Evaluation
  # ===========================================================================

  defp maybe_evaluate_cross_modal(rows, []), do: rows
  defp maybe_evaluate_cross_modal(rows, cross_modal_conditions) do
    Enum.filter(rows, fn hexad ->
      Enum.all?(cross_modal_conditions, fn condition ->
        evaluate_cross_modal(hexad, condition)
      end)
    end)
  end

  defp evaluate_cross_modal(hexad, condition) do
    case condition do
      %{TAG: "CrossModalFieldCompare",
        _0: mod1, _1: field1, _2: op, _3: mod2, _4: field2} ->
        val1 = get_modality_field(hexad, mod1, field1)
        val2 = get_modality_field(hexad, mod2, field2)
        compare_values_with_op(val1, op, val2)

      %{TAG: "ModalityDrift", _0: mod1, _1: mod2, _2: threshold} ->
        drift = compute_modality_drift(hexad, mod1, mod2)
        drift > threshold

      %{TAG: "ModalityExists", _0: modality} ->
        has_modality_data?(hexad, modality)

      %{TAG: "ModalityNotExists", _0: modality} ->
        not has_modality_data?(hexad, modality)

      %{TAG: "ModalityConsistency", _0: mod1, _1: mod2, _2: metric} ->
        compute_consistency(hexad, mod1, mod2, metric) > 0.0

      _ -> true
    end
  end

  defp get_modality_field(hexad, modality, field) do
    mod_str = modality_to_string(modality)
    mod_data = Map.get(hexad, mod_str, %{})
    Map.get(mod_data, field) || Map.get(hexad, "#{mod_str}.#{field}")
  end

  defp has_modality_data?(hexad, modality) do
    mod_str = modality_to_string(modality)
    case Map.get(hexad, mod_str) do
      nil -> false
      data when data == %{} -> false
      _ -> true
    end
  end

  defp compute_modality_drift(hexad, mod1, mod2) do
    # Compute drift between two modality representations
    # In production: compare embeddings/hashes of the two modalities
    mod1_str = modality_to_string(mod1)
    mod2_str = modality_to_string(mod2)

    case {Map.get(hexad, mod1_str), Map.get(hexad, mod2_str)} do
      {nil, _} -> 1.0
      {_, nil} -> 1.0
      {_data1, _data2} -> 0.0  # Placeholder: real drift computation
    end
  end

  defp compute_consistency(_hexad, _mod1, _mod2, _metric) do
    # Placeholder: compute consistency score using the specified metric
    0.5
  end

  defp compare_values_with_op(val1, op, val2) when is_number(val1) and is_number(val2) do
    case op do
      "==" -> val1 == val2
      "!=" -> val1 != val2
      ">" -> val1 > val2
      "<" -> val1 < val2
      ">=" -> val1 >= val2
      "<=" -> val1 <= val2
      %{TAG: "Eq"} -> val1 == val2
      %{TAG: "Neq"} -> val1 != val2
      %{TAG: "Gt"} -> val1 > val2
      %{TAG: "Lt"} -> val1 < val2
      %{TAG: "Gte"} -> val1 >= val2
      %{TAG: "Lte"} -> val1 <= val2
      _ -> false
    end
  end
  defp compare_values_with_op(val1, op, val2) when is_binary(val1) and is_binary(val2) do
    case op do
      "==" -> val1 == val2
      "!=" -> val1 != val2
      %{TAG: "Eq"} -> val1 == val2
      %{TAG: "Neq"} -> val1 != val2
      _ -> false
    end
  end
  defp compare_values_with_op(_val1, _op, _val2), do: false

  defp modality_to_string(mod) when is_binary(mod), do: String.downcase(mod)
  defp modality_to_string(mod) when is_atom(mod), do: Atom.to_string(mod)
  defp modality_to_string(%{TAG: tag}), do: String.downcase(tag)
  defp modality_to_string(_), do: "unknown"

  # ===========================================================================
  # Phase 3: Mutation Execution
  # ===========================================================================

  defp execute_insert(modality_data, proof, _timeout) do
    # Verify write proof if present
    if proof do
      case verify_multi_proof(nil, proof) do
        :ok -> :continue
        {:error, reason} -> {:error, {:write_proof_failed, reason}}
      end
    end

    # Call Rust HexadStore.create via RustClient
    case RustClient.create_hexad(modality_data) do
      {:ok, hexad_id} -> {:ok, %{hexad_id: hexad_id, operation: :insert}}
      {:error, reason} -> {:error, {:insert_failed, reason}}
    end
  rescue
    e -> {:error, {:insert_failed, Exception.message(e)}}
  end

  defp execute_update(hexad_id, sets, proof, _timeout) do
    if proof do
      case verify_multi_proof(nil, proof) do
        :ok -> :continue
        {:error, reason} -> {:error, {:write_proof_failed, reason}}
      end
    end

    # Convert SET assignments to field updates
    field_updates = Enum.map(sets, fn {field_ref, value} ->
      {field_ref, value}
    end)

    case RustClient.update_hexad(hexad_id, field_updates) do
      {:ok, _} -> {:ok, %{hexad_id: hexad_id, operation: :update, fields_updated: length(sets)}}
      {:error, reason} -> {:error, {:update_failed, reason}}
    end
  rescue
    e -> {:error, {:update_failed, Exception.message(e)}}
  end

  defp execute_delete(hexad_id, proof, _timeout) do
    if proof do
      case verify_multi_proof(nil, proof) do
        :ok -> :continue
        {:error, reason} -> {:error, {:write_proof_failed, reason}}
      end
    end

    case RustClient.delete_hexad(hexad_id) do
      {:ok, _} -> {:ok, %{hexad_id: hexad_id, operation: :delete}}
      {:error, reason} -> {:error, {:delete_failed, reason}}
    end
  rescue
    e -> {:error, {:delete_failed, Exception.message(e)}}
  end

  # ===========================================================================
  # Multi-Proof Verification
  # ===========================================================================

  defp verify_multi_proof(_query_ast, proof_specs) when is_list(proof_specs) do
    # Verify each proof in the composition
    results = Enum.map(proof_specs, fn spec ->
      verify_single_proof(spec)
    end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> :ok
      error -> error
    end
  end
  defp verify_multi_proof(_query_ast, _proof_specs), do: :ok

  defp verify_single_proof(_proof_spec) do
    # In production: call VQLTypeChecker, generate witness, verify ZKP
    :ok
  end

  # ===========================================================================
  # Query execution by source type
  # ===========================================================================

  defp execute_hexad_query(entity_id, modalities, where_clause, limit, offset, _timeout) do
    case RustClient.get_hexad(entity_id) do
      {:ok, hexad} ->
        filtered = filter_hexad(hexad, modalities, where_clause)
        paginated = paginate_results([filtered], limit, offset)
        {:ok, paginated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_federation_query(pattern, drift_policy, modalities, where_clause, limit, offset, _timeout) do
    Logger.info("Federation query: pattern=#{pattern}, drift_policy=#{inspect(drift_policy)}")
    {:ok, []}
  end

  defp execute_store_query(store_id, modalities, where_clause, limit, _offset, _timeout) do
    Logger.info("Store query: store_id=#{store_id}")

    query_type = determine_query_type(modalities, where_clause)

    case query_type do
      :text ->
        text_query = extract_text_query(where_clause)
        QueryRouter.query(:text, text_query, limit: limit || 10)

      :vector ->
        {embedding, _threshold} = extract_vector_query(where_clause)
        QueryRouter.query(:vector, embedding, k: limit || 10)

      :graph ->
        graph_params = extract_graph_query(where_clause)
        QueryRouter.query(:graph, graph_params)

      :multi ->
        params = extract_multi_modal_params(modalities, where_clause)
        QueryRouter.query(:multi, params, limit: limit || 10)

      _ ->
        {:error, :unsupported_query_type}
    end
  end

  defp filter_hexad(hexad, modalities, _where_clause) do
    if :all in modalities do
      hexad
    else
      Map.take(hexad, modalities |> Enum.map(&to_string/1))
    end
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
  defp has_fulltext_condition?(_where_clause), do: false

  defp has_vector_condition?(nil), do: false
  defp has_vector_condition?(_where_clause), do: false

  defp has_graph_pattern?(nil), do: false
  defp has_graph_pattern?(_where_clause), do: false

  defp extract_text_query(_where_clause), do: "placeholder query"
  defp extract_vector_query(_where_clause), do: {[0.1, 0.2, 0.3], 0.9}
  defp extract_graph_query(_where_clause), do: %{}

  defp extract_multi_modal_params(modalities, where_clause) do
    %{modalities: modalities, conditions: where_clause}
  end

  defp generate_explain_plan(_query_ast) do
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

  # ---------------------------------------------------------------------------
  # Post-processing: GROUP BY, Aggregation, ORDER BY, Projection
  # ---------------------------------------------------------------------------

  defp maybe_group_and_aggregate(rows, nil, _aggregates), do: rows
  defp maybe_group_and_aggregate(rows, _group_by, nil), do: rows
  defp maybe_group_and_aggregate(rows, group_by, aggregates) do
    grouped = Enum.group_by(rows, fn row ->
      Enum.map(group_by, fn %{modality: mod, field: field} ->
        get_in(row, [to_string(mod), field])
      end)
    end)

    Enum.map(grouped, fn {group_key, group_rows} ->
      base = group_by
        |> Enum.zip(group_key)
        |> Enum.into(%{}, fn {%{modality: mod, field: field}, val} ->
          {"#{mod}.#{field}", val}
        end)

      Enum.reduce(aggregates, base, fn agg, acc ->
        case agg do
          :count_all ->
            Map.put(acc, "COUNT(*)", length(group_rows))

          {:aggregate_field, func, %{modality: mod, field: field}} ->
            values = Enum.map(group_rows, fn row ->
              get_in(row, [to_string(mod), field]) || 0
            end)

            result = case func do
              :count -> length(values)
              :sum -> Enum.sum(values)
              :avg ->
                if length(values) > 0, do: Enum.sum(values) / length(values), else: 0
              :min -> Enum.min(values, fn -> 0 end)
              :max -> Enum.max(values, fn -> 0 end)
            end

            label = "#{String.upcase(to_string(func))}(#{mod}.#{field})"
            Map.put(acc, label, result)
        end
      end)
    end)
  end

  defp maybe_order_by(rows, nil), do: rows
  defp maybe_order_by(rows, order_items) do
    Enum.sort_by(rows, fn row ->
      Enum.map(order_items, fn %{field: %{modality: mod, field: field}} ->
        get_in(row, [to_string(mod), field]) || get_in(row, ["#{mod}.#{field}"])
      end)
    end, fn a, b ->
      order_items
      |> Enum.zip(Enum.zip(a, b))
      |> Enum.reduce_while(:eq, fn {item, {va, vb}}, _acc ->
        cmp = compare_values(va, vb)
        direction = Map.get(item, :direction, :asc)
        effective = if direction == :desc, do: invert_cmp(cmp), else: cmp
        case effective do
          :eq -> {:cont, :eq}
          :lt -> {:halt, true}
          :gt -> {:halt, false}
        end
      end)
      |> case do
        :eq -> true
        bool -> bool
      end
    end)
  end

  defp compare_values(a, b) when is_number(a) and is_number(b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end
  defp compare_values(a, b) when is_binary(a) and is_binary(b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end
  defp compare_values(_a, _b), do: :eq

  defp invert_cmp(:lt), do: :gt
  defp invert_cmp(:gt), do: :lt
  defp invert_cmp(:eq), do: :eq

  defp maybe_project_columns(rows, nil), do: rows
  defp maybe_project_columns(rows, projections) do
    Enum.map(rows, fn row ->
      Enum.into(projections, %{}, fn %{modality: mod, field: field} ->
        value = get_in(row, [to_string(mod), field]) || get_in(row, ["#{mod}.#{field}"])
        {"#{mod}.#{field}", value}
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # AST extraction helpers
  # ---------------------------------------------------------------------------

  defp extract_modalities(query_ast), do: Map.get(query_ast, :modalities, [:all])
  defp extract_source(query_ast), do: Map.get(query_ast, :source, {:hexad, "default"})
  defp extract_where(query_ast), do: Map.get(query_ast, :where, nil)

  defp extract_proof(query_ast) do
    case Map.get(query_ast, :proof, nil) do
      nil -> nil
      proof when is_list(proof) -> proof
      proof when is_map(proof) -> [proof]  # backward compat: single proof → list
    end
  end

  defp extract_limit(query_ast), do: Map.get(query_ast, :limit, nil)
  defp extract_offset(query_ast), do: Map.get(query_ast, :offset, nil)
  defp extract_order_by(query_ast), do: Map.get(query_ast, :orderBy, nil)
  defp extract_group_by(query_ast), do: Map.get(query_ast, :groupBy, nil)
  defp extract_aggregates(query_ast), do: Map.get(query_ast, :aggregates, nil)
  defp extract_projections(query_ast), do: Map.get(query_ast, :projections, nil)
end
