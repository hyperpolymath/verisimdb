# SPDX-License-Identifier: MPL-2.0

# Integration tests (7 adapter suites under
# test/verisim/federation/adapters/integration/) require the test-infra
# database stack (connectors/test-infra). They are opt-in per the
# documented flow — `mix test --include integration` — but were never
# actually excluded here, so bare `mix test` (what elixir-ci.yml runs)
# failed all 90 of them with "not available — start test-infra stack"
# on every CI run.
ExUnit.start(exclude: [:integration])
