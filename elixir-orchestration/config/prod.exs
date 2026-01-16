# SPDX-License-Identifier: AGPL-3.0-or-later

import Config

# Production configuration
config :verisim,
  rust_core_url: System.get_env("VERISIM_RUST_CORE_URL") || "http://verisim-core:8080/api/v1",
  rust_core_timeout: 60_000

config :logger, :console,
  level: :info
