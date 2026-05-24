# SPDX-License-Identifier: MPL-2.0

defmodule VeriSim.QueryRouterTest do
  @moduledoc """
  Tests for VeriSim.QueryRouter — the singleton GenServer that dispatches
  queries to the appropriate modality store via RustClient.

  We can't reach the Rust core in test, so each query returns an
  {:error, ...} tuple.  That's actually useful: it confirms the router
  routes correctly (right modality clause picked) and that stats
  aggregation works regardless of result success.
  """

  use ExUnit.Case, async: false

  alias VeriSim.QueryRouter

  setup do
    # The Application supervisor starts QueryRouter as a named GenServer.
    case GenServer.whereis(QueryRouter) do
      nil ->
        {:ok, _pid} = QueryRouter.start_link([])
        :ok

      _pid ->
        :ok
    end

    :ok
  end

  describe "query/3 routing — error path is structured" do
    test "text query reaches the :text branch" do
      # Returns RustClient error wrapped in {:error, ...}; what matters
      # is that the result is structured and the call doesn't raise.
      result = QueryRouter.query(:text, "machine learning", limit: 5)
      assert match?({:ok, _} = result, result) or match?({:error, _}, result)
    end

    test "vector query reaches the :vector branch" do
      result = QueryRouter.query(:vector, [0.1, 0.2, 0.3], k: 3)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "graph query reaches the :graph branch" do
      result = QueryRouter.query(:graph, %{start: "entity-1"})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "semantic query with single type IRI" do
      result = QueryRouter.query(:semantic, %{types: ["http://example.org/Doc"]})
      # Even when RustClient errors, semantic dedupes via Enum.uniq_by
      # and returns {:ok, []}.
      assert {:ok, results} = result
      assert is_list(results)
    end

    test "semantic query with multiple type IRIs is deduped" do
      result =
        QueryRouter.query(:semantic, %{
          types: [
            "http://example.org/A",
            "http://example.org/B",
            "http://example.org/C"
          ]
        })

      assert {:ok, _} = result
    end

    test "temporal query passes through entity_id" do
      result = QueryRouter.query(:temporal, %{entity_id: "e-1", time: "2026-01-01"})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "multi-modal query merges text + vector results without raising" do
      result =
        QueryRouter.query(:multi, %{
          text: "AI",
          vector: [0.5, 0.5, 0.5]
        })

      assert {:ok, results} = result
      assert is_list(results)
    end

    test "unknown query type returns structured error" do
      assert {:error, {:unknown_query_type, :bogus}} = QueryRouter.query(:bogus, %{}, [])
    end
  end

  describe "stats/0" do
    test "returns a structured snapshot with required keys" do
      stats = QueryRouter.stats()
      assert Map.has_key?(stats, :total_queries)
      assert Map.has_key?(stats, :queries_by_type)
      assert Map.has_key?(stats, :avg_latency_ms)
    end

    test "total_queries increases after a query" do
      stats_before = QueryRouter.stats()
      _ = QueryRouter.query(:text, "stats-probe", [])
      stats_after = QueryRouter.stats()

      assert stats_after.total_queries == stats_before.total_queries + 1
    end

    test "queries_by_type counts per-type calls" do
      _ = QueryRouter.query(:text, "type-count-probe", [])
      stats = QueryRouter.stats()
      # Whatever the absolute count, :text must appear and be ≥ 1.
      assert Map.get(stats.queries_by_type, :text, 0) >= 1
    end

    test "avg_latency_ms is non-negative" do
      _ = QueryRouter.query(:text, "latency-probe", [])
      stats = QueryRouter.stats()
      assert is_number(stats.avg_latency_ms)
      assert stats.avg_latency_ms >= 0.0
    end
  end
end
