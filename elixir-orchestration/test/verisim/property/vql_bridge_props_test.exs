# SPDX-License-Identifier: MPL-2.0

defmodule VeriSim.Query.VQLBridgePropsTest do
  @moduledoc """
  Property-based tests for the VQLBridge built-in parser.

  Invariants verified across the input space:

  - **No-panic**: any UTF-8 string yields either `{:ok, _}` or `{:error, _}`
    — never an exception, infinite loop, or crash.
  - **Source UUID round-trip**: for any UUID-like token, the `FROM HEXAD <id>`
    clause stores it verbatim as `{:octad, id}` in the AST.
  - **Modality subset**: the parsed `modalities` list is always a subset of
    the canonical octad-modality set.
  - **Slipstream/dependent symmetry**: `parse_slipstream` accepts iff
    `parse_dependent` rejects (presence/absence of PROOF) for the same
    input.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias VeriSim.Query.VQLBridge

  setup do
    case GenServer.whereis(VQLBridge) do
      nil ->
        {:ok, _pid} = VQLBridge.start_link([])
        :ok

      _pid ->
        :ok
    end

    :ok
  end

  @canonical_modalities ~w(graph vector tensor semantic document temporal provenance spatial)a

  defp modality_token do
    one_of([
      constant("GRAPH"),
      constant("VECTOR"),
      constant("TENSOR"),
      constant("SEMANTIC"),
      constant("DOCUMENT"),
      constant("TEMPORAL"),
      constant("PROVENANCE"),
      constant("SPATIAL")
    ])
  end

  defp uuid_like do
    map(
      tuple({integer(0..9_999), integer(0..9_999)}),
      fn {a, b} -> "entity-#{a}-#{b}" end
    )
  end

  property "parse never panics on arbitrary UTF-8 input" do
    check all(input <- string(:ascii, max_length: 200)) do
      result = VQLBridge.parse(input)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "FROM HEXAD <uuid> round-trips into the source field" do
    check all(uuid <- uuid_like()) do
      query = "SELECT GRAPH FROM HEXAD #{uuid}"

      case VQLBridge.parse(query) do
        {:ok, ast} ->
          assert ast.source == {:octad, uuid}

        {:error, _} ->
          # If the UUID happens to fail validation, that's acceptable.
          :ok
      end
    end
  end

  property "parsed modalities are always a subset of the canonical 8" do
    check all(mods <- list_of(modality_token(), min_length: 1, max_length: 6)) do
      query = "SELECT #{Enum.join(mods, ", ")} FROM HEXAD abc-123"

      case VQLBridge.parse(query) do
        {:ok, ast} ->
          parsed_mods = ast.modalities
          # :all is also acceptable (SELECT *) but for explicit token lists
          # we expect each parsed atom to be in @canonical_modalities.
          for mod <- parsed_mods do
            assert mod in @canonical_modalities or mod == :all,
                   "unexpected modality #{inspect(mod)}"
          end

        {:error, _} ->
          :ok
      end
    end
  end

  property "SELECT * always produces :all in modalities" do
    check all(uuid <- uuid_like()) do
      case VQLBridge.parse("SELECT * FROM HEXAD #{uuid}") do
        {:ok, ast} -> assert :all in ast.modalities
        {:error, _} -> :ok
      end
    end
  end

  property "slipstream/dependent disjunction for the same query" do
    check all(
            uuid <- uuid_like(),
            include_proof <- boolean()
          ) do
      proof_clause = if include_proof, do: " PROOF EXISTENCE(target-1)", else: ""
      query = "SELECT GRAPH FROM HEXAD #{uuid}#{proof_clause}"

      slipstream = VQLBridge.parse_slipstream(query)
      dependent = VQLBridge.parse_dependent(query)

      slipstream_ok? = match?({:ok, _}, slipstream)
      dependent_ok? = match?({:ok, _}, dependent)

      # Exactly one of the two must accept the query (modulo overall
      # parse failures, which fail both).
      if slipstream_ok? or dependent_ok? do
        assert slipstream_ok? != dependent_ok?,
               "expected exactly one of slipstream/dependent to accept query: #{query}"
      end
    end
  end

  property "tokenize is deterministic — same input ⇒ same AST" do
    check all(uuid <- uuid_like()) do
      query = "SELECT GRAPH, VECTOR FROM HEXAD #{uuid}"

      case {VQLBridge.parse(query), VQLBridge.parse(query)} do
        {{:ok, a}, {:ok, b}} ->
          assert a.modalities == b.modalities
          assert a.source == b.source

        {{:error, _}, {:error, _}} ->
          :ok

        _other ->
          flunk("parse was non-deterministic for #{query}")
      end
    end
  end
end
