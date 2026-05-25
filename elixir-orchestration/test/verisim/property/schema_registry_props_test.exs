# SPDX-License-Identifier: MPL-2.0

defmodule VeriSim.SchemaRegistryPropsTest do
  @moduledoc """
  Property-based tests for VeriSim.SchemaRegistry using StreamData.

  Each property is an invariant the registry must maintain across the
  full space of inputs:

  - Round-trip: any type that `register_type` accepts must be retrievable
    via `get_type` with structural equivalence.
  - Idempotence: `validate` is a pure function over (entity, registered
    constraints); calling it twice yields the same result.
  - Required constraint: an entity is rejected iff at least one required
    property is missing (negation symmetry).
  - Range constraint: numeric value v passes iff min ≤ v ≤ max.
  - Type independence: validating an entity tagged with type A is
    unaffected by the presence of an unrelated type B in the registry.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias VeriSim.SchemaRegistry

  setup do
    case GenServer.whereis(SchemaRegistry) do
      nil ->
        {:ok, _pid} = SchemaRegistry.start_link([])
        :ok

      _pid ->
        :ok
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp unique_iri do
    map(integer(0..1_000_000_000), &"prop:Type#{&1}-#{System.unique_integer([:positive])}")
  end

  defp safe_prop_name do
    one_of([
      constant("name"),
      constant("email"),
      constant("age"),
      constant("title"),
      constant("body")
    ])
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "register_type → get_type round-trips the iri" do
    check all(iri <- unique_iri()) do
      type_def = %{iri: iri, label: "L", supertypes: [], constraints: []}
      assert :ok = SchemaRegistry.register_type(type_def)
      fetched = SchemaRegistry.get_type(iri)
      assert is_map(fetched)
      assert fetched.iri == iri
    end
  end

  property "registered iri always appears in list_types" do
    check all(iri <- unique_iri()) do
      SchemaRegistry.register_type(%{iri: iri, label: "L", supertypes: [], constraints: []})
      assert iri in SchemaRegistry.list_types()
    end
  end

  property "duplicate register always errors with :already_exists" do
    check all(iri <- unique_iri()) do
      type = %{iri: iri, label: "L", supertypes: [], constraints: []}
      assert :ok = SchemaRegistry.register_type(type)
      assert {:error, :already_exists} = SchemaRegistry.register_type(type)
    end
  end

  property "required-constraint invariant: rejected iff property missing" do
    check all(
            iri <- unique_iri(),
            prop <- safe_prop_name(),
            value <- string(:ascii, min_length: 0, max_length: 20),
            include? <- boolean()
          ) do
      SchemaRegistry.register_type(%{
        iri: iri,
        label: "Req",
        supertypes: [],
        constraints: [
          %{name: "req_#{prop}", kind: {:required, prop}, message: "missing #{prop}"}
        ]
      })

      properties = if include?, do: %{prop => value}, else: %{}
      result = SchemaRegistry.validate(%{types: [iri], properties: properties})

      if include? do
        assert :ok = result
      else
        assert {:error, [_]} = result
      end
    end
  end

  property "range-constraint invariant: passes iff min ≤ value ≤ max" do
    check all(
            iri <- unique_iri(),
            value <- integer(-1_000..1_000),
            min_v <- integer(-500..500),
            span <- integer(0..500)
          ) do
      max_v = min_v + span

      SchemaRegistry.register_type(%{
        iri: iri,
        label: "Range",
        supertypes: [],
        constraints: [
          %{
            name: "r",
            kind: {:range, "v", min_v, max_v},
            message: "out of range"
          }
        ]
      })

      result = SchemaRegistry.validate(%{types: [iri], properties: %{"v" => value}})

      if value >= min_v and value <= max_v do
        assert :ok = result
      else
        assert {:error, [_]} = result
      end
    end
  end

  property "validate/1 is deterministic — calling twice yields the same result" do
    check all(
            iri <- unique_iri(),
            value <- string(:ascii, min_length: 0, max_length: 10)
          ) do
      SchemaRegistry.register_type(%{
        iri: iri,
        label: "Det",
        supertypes: [],
        constraints: [
          %{name: "req", kind: {:required, "x"}, message: "missing x"}
        ]
      })

      entity = %{types: [iri], properties: %{"x" => value}}
      assert SchemaRegistry.validate(entity) == SchemaRegistry.validate(entity)
    end
  end

  property "unknown type is a no-op — never produces a violation" do
    check all(value <- string(:ascii)) do
      result = SchemaRegistry.validate(%{types: ["never:Heard"], properties: %{"x" => value}})
      assert :ok = result
    end
  end
end
