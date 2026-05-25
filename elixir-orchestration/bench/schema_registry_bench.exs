# SPDX-License-Identifier: MPL-2.0
#
# SchemaRegistry constraint-validation throughput.

{:ok, _} = Application.ensure_all_started(:verisim)

alias VeriSim.SchemaRegistry

# Register a benchmark type with one constraint of each kind.
bench_iri = "bench:All"
_ =
  SchemaRegistry.register_type(%{
    iri: bench_iri,
    label: "Bench",
    supertypes: ["verisim:Entity"],
    constraints: [
      %{name: "name_req", kind: {:required, "name"}, message: "name required"},
      %{name: "email_pat", kind: {:pattern, "email", "^[^@]+@[^@]+$"}, message: "bad email"},
      %{name: "age_rng", kind: {:range, "age", 0, 150}, message: "age out of range"}
    ]
  })

ok_entity = %{
  types: [bench_iri],
  properties: %{"name" => "Alice", "email" => "a@b.com", "age" => 42}
}

bad_entity = %{
  types: [bench_iri],
  properties: %{"email" => "not-an-email", "age" => -5}
}

Benchee.run(
  %{
    "register_type/1 — fresh IRI" => fn ->
      iri = "bench:Type#{System.unique_integer([:positive])}"
      SchemaRegistry.register_type(%{iri: iri, label: "x", supertypes: [], constraints: []})
    end,
    "get_type/1 — hit (built-in)" => fn ->
      SchemaRegistry.get_type("verisim:Document")
    end,
    "get_type/1 — miss" => fn ->
      SchemaRegistry.get_type("nothing:Here")
    end,
    "list_types/0" => fn ->
      SchemaRegistry.list_types()
    end,
    "validate/1 — passing entity (3 constraints)" => fn ->
      SchemaRegistry.validate(ok_entity)
    end,
    "validate/1 — failing entity (2 violations)" => fn ->
      SchemaRegistry.validate(bad_entity)
    end,
    "validate/1 — no-op (no types)" => fn ->
      SchemaRegistry.validate(%{properties: %{}})
    end,
    "type_hierarchy/1 — built-in chain" => fn ->
      SchemaRegistry.type_hierarchy("verisim:Document")
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 1,
  print: [fast_warning: false],
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.JSON, file: "bench/results/schema_registry.json"}
  ]
)
