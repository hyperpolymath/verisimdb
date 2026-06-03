# SPDX-License-Identifier: MPL-2.0

ExUnit.start()

# Federation-adapter integration tests are tagged `@moduletag :integration` and
# require the live test-infra database stack (MongoDB, Redis, Neo4j, ClickHouse,
# SurrealDB, InfluxDB, object storage). They cannot run on a plain CI runner, so
# they are EXCLUDED by default; their `skip_if_unavailable/1` guard otherwise
# turns "DB not reachable" into a hard failure rather than a skip.
#
# Run them with the stack up via:  mix test --include integration
# (see CLAUDE.md "Federation Adapter Integration Tests").
ExUnit.configure(exclude: [:integration])
