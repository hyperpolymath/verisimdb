# SPDX-License-Identifier: MPL-2.0

defmodule VeriSim.EntityServerTest do
  @moduledoc """
  Tests for VeriSim.EntityServer — the per-entity GenServer that owns
  modality state and coordinates normalization.

  Each EntityServer is registered under {VeriSim.EntityRegistry,
  entity_id}, which is started by VeriSim.Application.  These tests
  use the app-managed registry and generate unique entity IDs per test
  to avoid cross-test pollution.

  Async paths that depend on RustClient (snapshotting via
  /octads/:id/versions, normalize/1) are exercised by allowing the
  cast to complete — RustClient returns {:error, ...} when the Rust
  core is unreachable, which keeps the GenServer alive and lets us
  assert the state transition.
  """

  use ExUnit.Case, async: false

  alias VeriSim.EntityServer

  setup do
    # Each test gets a fresh entity ID; the EntityRegistry is shared
    # across the test suite (app-managed).
    entity_id = "test-entity-#{System.unique_integer([:positive])}"
    {:ok, pid} = EntityServer.start_link(entity_id)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, entity_id: entity_id, pid: pid}
  end

  describe "init/1" do
    test "starts with all modalities marked false", %{entity_id: id} do
      {:ok, state} = EntityServer.get(id)
      assert state.id == id
      assert state.status == :active
      assert state.version == 0
      assert state.drift_score == 0.0

      for modality <- [:graph, :vector, :tensor, :semantic, :document, :temporal] do
        assert Map.get(state.modalities, modality) == false,
               "expected #{modality} to start false"
      end
    end

    test "last_modified is a recent timestamp", %{entity_id: id} do
      {:ok, state} = EntityServer.get(id)
      assert %DateTime{} = state.last_modified
      assert DateTime.diff(DateTime.utc_now(), state.last_modified, :second) < 5
    end
  end

  describe "update/2" do
    test "modality flag updates land in state.modalities", %{entity_id: id} do
      {:ok, new_state} =
        EntityServer.update(id, [
          {:modality, :vector, true},
          {:modality, :document, true}
        ])

      assert new_state.modalities.vector == true
      assert new_state.modalities.document == true
      assert new_state.modalities.graph == false
    end

    test "top-level atom keys merge into state", %{entity_id: id} do
      {:ok, new_state} = EntityServer.update(id, [{:drift_score, 0.42}])
      assert new_state.drift_score == 0.42
    end

    test "version is bumped on each update", %{entity_id: id} do
      {:ok, v1} = EntityServer.update(id, [{:modality, :graph, true}])
      {:ok, v2} = EntityServer.update(id, [{:modality, :vector, true}])

      assert v2.version == v1.version + 1
      assert v1.version == 1
    end

    test "last_modified moves forward on update", %{entity_id: id} do
      {:ok, before_state} = EntityServer.get(id)
      Process.sleep(10)
      {:ok, after_state} = EntityServer.update(id, [{:modality, :tensor, true}])

      assert DateTime.compare(after_state.last_modified, before_state.last_modified) == :gt
    end

    test "non-recognised tuples are silently ignored", %{entity_id: id} do
      {:ok, before_state} = EntityServer.get(id)
      {:ok, after_state} = EntityServer.update(id, ["bogus", {:invalid, :shape}])

      # version still bumps (we applied the no-op update), but no
      # modalities or other fields change.
      assert after_state.version == before_state.version + 1
      assert after_state.modalities == before_state.modalities
    end
  end

  describe "modality_status/1" do
    test "returns just the modalities sub-map", %{entity_id: id} do
      {:ok, _} =
        EntityServer.update(id, [
          {:modality, :semantic, true},
          {:modality, :temporal, true}
        ])

      {:ok, modalities} = EntityServer.modality_status(id)
      assert modalities.semantic == true
      assert modalities.temporal == true
      assert modalities.graph == false
      assert map_size(modalities) == 6
    end
  end

  describe "normalize/1" do
    test "cast transitions status to :normalizing immediately", %{entity_id: id} do
      :ok = EntityServer.normalize(id)
      # Cast → call to flush.
      {:ok, state} = EntityServer.get(id)
      assert state.status == :normalizing
    end

    test "subsequent updates still work while normalizing", %{entity_id: id} do
      :ok = EntityServer.normalize(id)
      {:ok, after_update} = EntityServer.update(id, [{:modality, :graph, true}])

      assert after_update.modalities.graph == true
      # Status stays :normalizing until async normalization completes.
      assert after_update.status == :normalizing
    end
  end

  describe "process registration via Registry" do
    test "via_tuple routes to the same process across calls", %{entity_id: id, pid: pid} do
      [{registered_pid, _}] = Registry.lookup(VeriSim.EntityRegistry, id)
      assert registered_pid == pid
    end

    test "second start_link with the same id fails", %{entity_id: id} do
      assert {:error, {:already_started, _}} = EntityServer.start_link(id)
    end
  end
end
