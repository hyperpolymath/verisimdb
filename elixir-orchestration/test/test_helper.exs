# SPDX-License-Identifier: MPL-2.0

# Integration tests (federation adapters and anything else needing live
# external services) are excluded by default so plain `mix test` is
# self-contained. Run them with: mix test --include integration
ExUnit.start(exclude: [:integration])
