# SPDX-License-Identifier: AGPL-3.0-or-later

import Config

# Runtime configuration loaded at application start
if config_env() == :prod do
  config :verisim,
    rust_core_url: System.get_env("VERISIM_RUST_CORE_URL") || "http://localhost:8080/api/v1",
    rust_core_timeout: String.to_integer(System.get_env("VERISIM_RUST_CORE_TIMEOUT") || "30000")
end
