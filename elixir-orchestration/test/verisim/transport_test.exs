# SPDX-License-Identifier: MPL-2.0

defmodule VeriSim.TransportTest do
  # async: false — these tests mutate the VERISIM_TRANSPORT OS env var.
  use ExUnit.Case, async: false

  alias VeriSim.{NifBridge, Transport}

  setup do
    prior = System.get_env("VERISIM_TRANSPORT")

    on_exit(fn ->
      if prior,
        do: System.put_env("VERISIM_TRANSPORT", prior),
        else: System.delete_env("VERISIM_TRANSPORT")
    end)

    :ok
  end

  describe "transport mode selection" do
    test "defaults to :http when unset" do
      System.delete_env("VERISIM_TRANSPORT")
      assert Transport.mode() == :http
      refute Transport.use_nif?()
    end

    test "explicit nif selects :nif" do
      System.put_env("VERISIM_TRANSPORT", "nif")
      assert Transport.mode() == :nif
    end

    test "auto does NOT select the NIF while it is non-operational" do
      System.put_env("VERISIM_TRANSPORT", "auto")
      assert Transport.mode() == :auto
      # No operation is implemented (every NIF/stub returns an error), so the
      # bridge is non-operational and auto must fall back to HTTP. This is the
      # guard against silently routing writes into a NIF that does nothing.
      refute Transport.use_nif?()
    end

    test "unknown value falls back to :http" do
      System.put_env("VERISIM_TRANSPORT", "banana")
      assert Transport.mode() == :http
    end
  end

  describe "the NIF bridge never fabricates success (regression for silent data loss)" do
    test "every operation returns an error tuple, never fake success" do
      # The previous Rust NIF returned canned success (e.g. delete -> "deleted")
      # having done nothing. After the fail-loudly fix, the compiled NIF and the
      # pure-Elixir stub are indistinguishable: both error, neither fabricates.
      assert {:error, _} = NifBridge.create_octad(~s({"document":{"title":"t","body":"b"}}))
      assert {:error, _} = NifBridge.get_octad("e-1")
      assert {:error, _} = NifBridge.delete_octad("e-1")
      assert {:error, _} = NifBridge.search_text("q", 10)
      assert {:error, _} = NifBridge.search_vector("[0.1,0.2,0.3]", 5)
      assert {:error, _} = NifBridge.list_octads(10, 0)
      assert {:error, _} = NifBridge.get_drift_score("e-1")
      assert {:error, _} = NifBridge.trigger_normalise("e-1")
    end

    test "loaded? is false when no operation is operational" do
      refute NifBridge.loaded?()
    end
  end

  describe "health does not fake success under an explicit nif transport" do
    test "nif health reports not operational, never {:ok, healthy}" do
      System.put_env("VERISIM_TRANSPORT", "nif")
      assert {:error, :nif_not_operational} = Transport.health()
    end
  end
end
