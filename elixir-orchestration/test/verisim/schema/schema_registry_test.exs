# SPDX-License-Identifier: MPL-2.0

defmodule VeriSim.SchemaRegistryTest do
  @moduledoc """
  Tests for VeriSim.SchemaRegistry — the named GenServer that owns the
  type system (built-ins + user types) and runs constraint validation.

  Each test uses unique type IRIs to avoid collisions with built-in types
  and with parallel tests.  The registry is started by the Application
  supervisor.
  """

  use ExUnit.Case, async: false

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

  describe "built-in types" do
    test "verisim:Entity is registered at startup" do
      assert is_map(SchemaRegistry.get_type("verisim:Entity"))
    end

    test "verisim:Document is registered with a title_required constraint" do
      doc = SchemaRegistry.get_type("verisim:Document")
      assert is_map(doc)
      assert doc.supertypes == ["verisim:Entity"]
      assert Enum.any?(doc.constraints, fn c -> c.name == "title_required" end)
    end

    test "list_types includes the 4 built-ins" do
      types = SchemaRegistry.list_types()
      assert "verisim:Entity" in types
      assert "verisim:Document" in types
      assert "verisim:Node" in types
      assert "verisim:TimeSeries" in types
    end
  end

  describe "register_type/1" do
    test "successfully registers a new type" do
      iri = "test:Type#{System.unique_integer([:positive])}"

      assert :ok =
               SchemaRegistry.register_type(%{
                 iri: iri,
                 label: "Test",
                 supertypes: [],
                 constraints: []
               })

      assert is_map(SchemaRegistry.get_type(iri))
    end

    test "rejects duplicate registration" do
      iri = "test:Dup#{System.unique_integer([:positive])}"
      type = %{iri: iri, label: "Dup", supertypes: [], constraints: []}

      assert :ok = SchemaRegistry.register_type(type)
      assert {:error, :already_exists} = SchemaRegistry.register_type(type)
    end

    test "registered type appears in list_types" do
      iri = "test:Listed#{System.unique_integer([:positive])}"

      SchemaRegistry.register_type(%{
        iri: iri,
        label: "Listed",
        supertypes: [],
        constraints: []
      })

      assert iri in SchemaRegistry.list_types()
    end
  end

  describe "get_type/1" do
    test "unknown IRI returns nil" do
      assert SchemaRegistry.get_type("never:Exists") == nil
    end
  end

  describe "validate/1 — required constraint" do
    setup do
      iri = "test:Required#{System.unique_integer([:positive])}"

      SchemaRegistry.register_type(%{
        iri: iri,
        label: "Required",
        supertypes: [],
        constraints: [
          %{name: "name_req", kind: {:required, "name"}, message: "name is required"}
        ]
      })

      {:ok, type: iri}
    end

    test "entity missing required property is rejected", %{type: iri} do
      assert {:error, ["name is required"]} =
               SchemaRegistry.validate(%{types: [iri], properties: %{}})
    end

    test "entity with required property is accepted", %{type: iri} do
      assert :ok = SchemaRegistry.validate(%{types: [iri], properties: %{"name" => "Alice"}})
    end
  end

  describe "validate/1 — pattern constraint" do
    setup do
      iri = "test:Pattern#{System.unique_integer([:positive])}"

      SchemaRegistry.register_type(%{
        iri: iri,
        label: "Pattern",
        supertypes: [],
        constraints: [
          %{
            name: "email_format",
            kind: {:pattern, "email", "^[^@]+@[^@]+$"},
            message: "email must be valid"
          }
        ]
      })

      {:ok, type: iri}
    end

    test "missing property is allowed (pattern only checks when present)", %{type: iri} do
      assert :ok = SchemaRegistry.validate(%{types: [iri], properties: %{}})
    end

    test "matching value is accepted", %{type: iri} do
      assert :ok =
               SchemaRegistry.validate(%{
                 types: [iri],
                 properties: %{"email" => "a@b.com"}
               })
    end

    test "non-matching value is rejected", %{type: iri} do
      assert {:error, ["email must be valid"]} =
               SchemaRegistry.validate(%{
                 types: [iri],
                 properties: %{"email" => "not-an-email"}
               })
    end
  end

  describe "validate/1 — range constraint" do
    setup do
      iri = "test:Range#{System.unique_integer([:positive])}"

      SchemaRegistry.register_type(%{
        iri: iri,
        label: "Range",
        supertypes: [],
        constraints: [
          %{
            name: "age_range",
            kind: {:range, "age", 0, 150},
            message: "age must be 0-150"
          }
        ]
      })

      {:ok, type: iri}
    end

    test "value inside range is accepted", %{type: iri} do
      assert :ok = SchemaRegistry.validate(%{types: [iri], properties: %{"age" => 42}})
    end

    test "value below minimum is rejected", %{type: iri} do
      assert {:error, ["age must be 0-150"]} =
               SchemaRegistry.validate(%{types: [iri], properties: %{"age" => -1}})
    end

    test "value above maximum is rejected", %{type: iri} do
      assert {:error, ["age must be 0-150"]} =
               SchemaRegistry.validate(%{types: [iri], properties: %{"age" => 200}})
    end

    test "non-numeric value is silently ignored", %{type: iri} do
      assert :ok = SchemaRegistry.validate(%{types: [iri], properties: %{"age" => "old"}})
    end
  end

  describe "validate/1 — unknown type" do
    test "entity tagged with an unregistered type passes validation" do
      assert :ok = SchemaRegistry.validate(%{types: ["bogus:Type"], properties: %{}})
    end

    test "entity with no types passes validation" do
      assert :ok = SchemaRegistry.validate(%{properties: %{}})
    end
  end

  describe "type_hierarchy/1" do
    test "built-in verisim:Document hierarchy includes verisim:Entity" do
      hierarchy = SchemaRegistry.type_hierarchy("verisim:Document")
      assert "verisim:Entity" in hierarchy or hierarchy == ["verisim:Entity"]
    end

    test "unknown type returns an empty or singleton hierarchy" do
      hierarchy = SchemaRegistry.type_hierarchy("never:Heard:Of")
      assert is_list(hierarchy)
    end

    test "custom type with chained supertypes resolves" do
      iri = "test:Chain#{System.unique_integer([:positive])}"

      SchemaRegistry.register_type(%{
        iri: iri,
        label: "Chain",
        supertypes: ["verisim:Document"],
        constraints: []
      })

      hierarchy = SchemaRegistry.type_hierarchy(iri)
      assert "verisim:Document" in hierarchy
    end
  end
end
