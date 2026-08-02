# SPDX-License-Identifier: MPL-2.0

defmodule VeriSim.Query.VCLBridgeTest do
  @moduledoc """
  Tests for VeriSim.Query.VCLBridge — the Elixir↔Deno bridge for the
  ReScript VCL parser.

  When the external Deno/Node subprocess is unavailable (which is the
  common case in CI without those runtimes), the bridge falls back to
  a pure-Elixir built-in parser.  These tests exercise that fallback
  path through the public GenServer API — they're guaranteed to hit
  the fallback because no subprocess is started in the test
  environment.

  `typecheck/2` has no fallback (it requires the ReScript bidirectional
  checker), so it must return `{:error, :type_checker_unavailable}`
  when the port is nil.
  """

  use ExUnit.Case, async: false

  alias VeriSim.Query.VCLBridge

  setup do
    case GenServer.whereis(VCLBridge) do
      nil ->
        {:ok, _pid} = VCLBridge.start_link([])
        :ok

      _pid ->
        :ok
    end

    :ok
  end

  describe "parse/2 — built-in fallback" do
    test "parses a simple SELECT query" do
      assert {:ok, ast} = VCLBridge.parse("SELECT GRAPH FROM HEXAD abc-123")
      assert is_map(ast)
      assert Map.has_key?(ast, :modalities)
      assert Map.has_key?(ast, :source)
    end

    test "parses multi-modality SELECT" do
      assert {:ok, ast} = VCLBridge.parse("SELECT GRAPH, VECTOR, DOCUMENT FROM HEXAD abc-123")

      assert :graph in ast.modalities
      assert :vector in ast.modalities
      assert :document in ast.modalities
    end

    test "parses SELECT * as :all" do
      assert {:ok, ast} = VCLBridge.parse("SELECT * FROM HEXAD abc-123")
      assert :all in ast.modalities
    end

    test "captures the source UUID from FROM HEXAD clause" do
      assert {:ok, ast} = VCLBridge.parse("SELECT GRAPH FROM HEXAD entity-xyz")
      assert match?({:octad, "entity-xyz"}, ast.source)
    end

    test "non-SELECT input returns {:error, _}" do
      assert {:error, _} = VCLBridge.parse("HELLO WORLD")
    end

    test "empty string returns {:error, _}" do
      assert {:error, _} = VCLBridge.parse("")
    end
  end

  describe "parse_slipstream/2" do
    test "accepts a query without PROOF" do
      assert {:ok, _ast} = VCLBridge.parse_slipstream("SELECT GRAPH FROM HEXAD abc-123")
    end

    test "rejects a query with PROOF clause" do
      assert {:error, msg} =
               VCLBridge.parse_slipstream(
                 "SELECT GRAPH FROM HEXAD abc-123 PROOF EXISTENCE(entity-001)"
               )

      assert is_binary(msg)
      assert String.contains?(msg, "PROOF") or String.contains?(msg, "Slipstream")
    end
  end

  describe "parse_dependent/2" do
    test "rejects a query without PROOF clause" do
      assert {:error, _msg} = VCLBridge.parse_dependent("SELECT GRAPH FROM HEXAD abc-123")
    end

    test "accepts a query with PROOF clause" do
      assert {:ok, ast} =
               VCLBridge.parse_dependent(
                 "SELECT GRAPH FROM HEXAD abc-123 PROOF EXISTENCE(entity-001)"
               )

      assert ast.proof != nil
    end
  end

  describe "parse_mutation/2" do
    test "parses INSERT statement" do
      assert {:ok, mutation} =
               VCLBridge.parse_mutation("INSERT HEXAD WITH GRAPH {} AND VECTOR {}")

      assert is_map(mutation)
    end

    test "parses UPDATE statement" do
      assert {:ok, mutation} = VCLBridge.parse_mutation("UPDATE HEXAD abc-123 SET GRAPH {}")

      assert is_map(mutation)
    end

    test "parses DELETE statement" do
      assert {:ok, mutation} = VCLBridge.parse_mutation("DELETE HEXAD abc-123")
      assert is_map(mutation)
    end

    test "non-mutation input returns {:error, _}" do
      assert {:error, _} = VCLBridge.parse_mutation("SELECT GRAPH FROM HEXAD x")
    end
  end

  describe "parse_statement/2" do
    test "routes SELECT to Query tag" do
      assert {:ok, %{TAG: "Query"}} = VCLBridge.parse_statement("SELECT GRAPH FROM HEXAD abc-123")
    end

    test "routes INSERT to Mutation tag" do
      assert {:ok, %{TAG: "Mutation"}} =
               VCLBridge.parse_statement("INSERT HEXAD WITH GRAPH {} AND VECTOR {}")
    end

    test "routes DELETE to Mutation tag" do
      assert {:ok, %{TAG: "Mutation"}} = VCLBridge.parse_statement("DELETE HEXAD abc-123")
    end
  end

  describe "typecheck/2" do
    test "returns :type_checker_unavailable when no ReScript subprocess" do
      # In test env the Deno/Node subprocess isn't started, so the
      # typecheck handler returns this specific error rather than
      # silently passing.  Critical for VCL-DT integrity.
      ast = %{modalities: [:graph], source: {:octad, "abc"}}
      assert {:error, :type_checker_unavailable} = VCLBridge.typecheck(ast)
    end
  end

  describe "parse_and_execute/2 — error propagation" do
    test "parse failure propagates" do
      assert {:error, _} = VCLBridge.parse_and_execute("INVALID GIBBERISH", [])
    end
  end
end
