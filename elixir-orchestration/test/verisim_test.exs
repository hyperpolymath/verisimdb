# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule VeriSimTest do
  use ExUnit.Case
  doctest VeriSim

  test "version returns string" do
    assert is_binary(VeriSim.version())
  end
end
