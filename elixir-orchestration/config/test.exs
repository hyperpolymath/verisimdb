# SPDX-License-Identifier: AGPL-3.0-or-later

import Config

# Test configuration
config :verisim,
  rust_core_url: "http://localhost:8081/api/v1",
  rust_core_timeout: 5_000

config :logger, :console,
  level: :warning
