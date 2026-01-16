# SPDX-License-Identifier: AGPL-3.0-or-later

import Config

# Development-specific configuration
config :verisim,
  rust_core_url: "http://localhost:8080/api/v1"

config :logger, :console,
  level: :debug
