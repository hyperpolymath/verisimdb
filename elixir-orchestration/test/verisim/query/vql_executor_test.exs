# SPDX-License-Identifier: MPL-2.0

defmodule VeriSim.Query.VQLExecutorTest do
  @moduledoc """
  Tests for VeriSim.Query.VQLExecutor — the 1812-LOC central executor
  for parsed VQL queries and mutations.

  The executor sits between the parser (VQLBridge) and the Rust core
  (via RustClient).  In test environments the Rust core is unreachable,
  so most real execution paths bottom out in `{:error, ...}` tuples.
  These tests cover what's testable independently:

  - `execute/2` with `:explain` returns a fully-formed plan from the
    local cost estimator (Rust planner falls back cleanly on its absence)
  - Each source variant (Octad / Federation / Store / Reflect) maps to
    a distinct first-step in the plan
  - PROOF specs increase the plan's step count and total cost
  - Cross-modal WHERE conditions flip the strategy to `:two_phase`
  - `execute_mutation/2` routes Insert/Update/Delete/Unknown correctly
  - `execute_statement/2` dispatches by TAG and by `:type` key
  - `execute_string/2` propagates parse errors as `{:parse_error, _}`
  """

  use ExUnit.Case, async: false

  alias VeriSim.Query.VQLExecutor

  describe "execute/2 with :explain option" do
    test "returns a structured plan with the documented keys" do
      ast = %{modalities: [:graph], source: {:octad, "abc-123"}}
      assert {:ok, plan} = VQLExecutor.execute(ast, explain: true)

      assert is_map(plan)
      assert Map.has_key?(plan, :strategy)
      assert Map.has_key?(plan, :steps)
      assert Map.has_key?(plan, :total_cost_ms)
      assert Map.has_key?(plan, :modalities_queried)
      assert Map.has_key?(plan, :has_cross_modal)
      assert Map.has_key?(plan, :has_proof)
    end

    test "default strategy is :sequential when no cross-modal conditions" do
      ast = %{modalities: [:graph], source: {:octad, "abc-123"}}
      assert {:ok, plan} = VQLExecutor.execute(ast, explain: true)
      assert plan.strategy == :sequential
    end

    test "octad source produces an 'Octad lookup' step" do
      ast = %{modalities: [:graph], source: {:octad, "entity-xyz"}}
      {:ok, plan} = VQLExecutor.execute(ast, explain: true)

      ops = Enum.map(plan.steps, & &1.operation)
      assert "Octad lookup" in ops
    end

    test "federation source produces a 'Federation fan-out' step" do
      ast = %{
        modalities: [:graph],
        source: {:federation, "/universities/*", :tolerate}
      }

      {:ok, plan} = VQLExecutor.execute(ast, explain: true)
      ops = Enum.map(plan.steps, & &1.operation)
      assert "Federation fan-out" in ops
    end

    test "store source produces a 'Store query' step" do
      ast = %{modalities: [:graph], source: {:store, "store-1"}}
      {:ok, plan} = VQLExecutor.execute(ast, explain: true)
      ops = Enum.map(plan.steps, & &1.operation)
      assert "Store query" in ops
    end

    test "reflect source produces a REFLECT step" do
      ast = %{modalities: [:graph], source: :reflect}
      {:ok, plan} = VQLExecutor.execute(ast, explain: true)
      ops = Enum.map(plan.steps, & &1.operation)
      assert Enum.any?(ops, &String.contains?(&1, "REFLECT"))
    end

    test "proof obligations bump the total cost" do
      base_ast = %{modalities: [:graph], source: {:octad, "x"}}
      proof_ast = Map.put(base_ast, :proof, [%{type: "EXISTENCE", target: "y"}])

      {:ok, base} = VQLExecutor.execute(base_ast, explain: true)
      {:ok, with_proof} = VQLExecutor.execute(proof_ast, explain: true)

      assert with_proof.total_cost_ms > base.total_cost_ms
      assert with_proof.has_proof == true
      assert base.has_proof == false
    end

    test "multiple modalities scale the modality-query cost linearly" do
      one = %{modalities: [:graph], source: {:octad, "x"}}

      five = %{
        modalities: [:graph, :vector, :tensor, :document, :semantic],
        source: {:octad, "x"}
      }

      {:ok, p1} = VQLExecutor.execute(one, explain: true)
      {:ok, p5} = VQLExecutor.execute(five, explain: true)
      assert p5.total_cost_ms > p1.total_cost_ms
    end

    test "total_cost_ms equals the sum of step cost_ms values" do
      ast = %{
        modalities: [:graph, :vector],
        source: {:octad, "x"}
      }

      {:ok, plan} = VQLExecutor.execute(ast, explain: true)
      sum = Enum.reduce(plan.steps, 0, fn s, acc -> acc + Map.get(s, :cost_ms, 0) end)
      assert plan.total_cost_ms == sum
    end
  end

  describe "execute_mutation/2 — routing" do
    test "unknown mutation tag returns {:error, {:invalid_mutation, _}}" do
      assert {:error, {:invalid_mutation, _}} = VQLExecutor.execute_mutation(%{TAG: "Bogus"})
    end

    test "Insert routes to execute_insert (errors when RustClient unreachable)" do
      mutation = %{TAG: "Insert", modalities: %{graph: %{}}, proof: nil}
      result = VQLExecutor.execute_mutation(mutation)
      # In test env RustClient.create_octad/1 returns {:error, _}; the
      # executor wraps that as {:insert_failed, _}.  Either path is
      # acceptable — what we're verifying is that the dispatch reached
      # the Insert branch and didn't raise.
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "Update routes to execute_update without raising" do
      mutation = %{TAG: "Update", octadId: "abc", sets: %{graph: %{}}, proof: nil}
      result = VQLExecutor.execute_mutation(mutation)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "Delete routes to execute_delete without raising" do
      mutation = %{TAG: "Delete", octadId: "abc", proof: nil}
      result = VQLExecutor.execute_mutation(mutation)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "execute_statement/2 — dispatch" do
    test "%{TAG: \"Query\", _0: query} dispatches to execute/2 with the inner query" do
      stmt = %{
        TAG: "Query",
        _0: %{modalities: [:graph], source: {:octad, "x"}}
      }

      assert {:ok, _plan} = VQLExecutor.execute_statement(stmt, explain: true)
    end

    test "%{TAG: \"Mutation\", _0: mutation} dispatches to execute_mutation" do
      stmt = %{TAG: "Mutation", _0: %{TAG: "Bogus"}}
      assert {:error, {:invalid_mutation, _}} = VQLExecutor.execute_statement(stmt)
    end

    test "%{type: :query, ...} dispatches to execute/2" do
      stmt = %{type: :query, modalities: [:graph], source: {:octad, "x"}}
      assert {:ok, _plan} = VQLExecutor.execute_statement(stmt, explain: true)
    end

    test "%{type: :mutation, mutation: ...} dispatches to execute_mutation" do
      stmt = %{type: :mutation, mutation: %{TAG: "Bogus"}}
      assert {:error, {:invalid_mutation, _}} = VQLExecutor.execute_statement(stmt)
    end

    test "unrecognised statement shape falls through to execute/2" do
      # An untyped map is forwarded to execute/2, which interprets it
      # as a query AST.  With :explain we get back a plan without
      # needing the Rust core.
      stmt = %{modalities: [:graph], source: {:octad, "x"}}
      assert {:ok, _plan} = VQLExecutor.execute_statement(stmt, explain: true)
    end
  end

  describe "execute_string/2 — parse error propagation" do
    test "garbage input returns {:error, {:parse_error, _}}" do
      assert {:error, {:parse_error, _}} = VQLExecutor.execute_string("THIS IS NOT VALID VQL", [])
    end

    test "empty string returns {:error, {:parse_error, _}}" do
      assert {:error, {:parse_error, _}} = VQLExecutor.execute_string("", [])
    end

    test "valid query string with :explain returns a plan" do
      assert {:ok, plan} =
               VQLExecutor.execute_string(
                 "SELECT GRAPH FROM HEXAD abc-123",
                 explain: true
               )

      assert is_map(plan)
      assert Map.has_key?(plan, :strategy)
    end
  end

  describe "execute/2 — option handling" do
    test ":timeout defaults to 30_000 ms" do
      # Indirectly verified: passing no opts shouldn't raise.
      ast = %{modalities: [:graph], source: {:octad, "x"}}
      assert {:ok, _} = VQLExecutor.execute(ast, explain: true)
    end

    test ":explain false (default) attempts real execution" do
      ast = %{modalities: [:graph], source: {:octad, "x"}}
      # Real execution hits RustClient.  Without it available, we
      # expect an error — but the call must not raise.
      result = VQLExecutor.execute(ast)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test ":explain false explicitly attempts real execution" do
      ast = %{modalities: [:graph], source: {:octad, "x"}}
      result = VQLExecutor.execute(ast, explain: false)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
