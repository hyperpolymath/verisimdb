# SPDX-License-Identifier: MPL-2.0

defmodule VeriSim.Consensus.KRaftSupervisorTest do
  @moduledoc """
  Tests for VeriSim.Consensus.KRaftSupervisor — the supervisor that
  starts the local Registry and a configurable list of KRaftNode
  processes.

  The supervisor uses `name: __MODULE__`, so only one instance can be
  running at a time.  These tests start it under a different name via
  Supervisor.start_link directly so they don't conflict with any
  app-managed instance.
  """

  use ExUnit.Case, async: false

  alias VeriSim.Consensus.KRaftSupervisor

  describe "start_link/1 — empty cluster" do
    test "starts cleanly with no nodes" do
      # Empty list: only the Registry child should be started.
      # We test the init/1 callback's child-spec generation directly to
      # avoid needing a unique supervisor name.
      {:ok, children_specs} = KRaftSupervisor.init(nodes: [])
      assert is_tuple(children_specs)
    end
  end

  describe "child spec generation" do
    test "init/1 returns a Supervisor child-spec tuple with one_for_one strategy" do
      {:ok, {sup_flags, children}} = KRaftSupervisor.init(nodes: [])

      assert sup_flags.strategy == :one_for_one
      assert is_list(children)
      assert length(children) == 1
    end

    test "the only child for an empty cluster is the consensus Registry" do
      {:ok, {_flags, children}} = KRaftSupervisor.init(nodes: [])

      [registry_spec] = children
      # Registry.child_spec/1 uses the :name option as the child id.
      assert registry_spec.id == VeriSim.Consensus.Registry
    end

    test "one configured node yields Registry + one KRaftNode spec" do
      {:ok, {_flags, children}} =
        KRaftSupervisor.init(
          nodes: [
            [node_id: "n1", peers: []]
          ]
        )

      assert length(children) == 2
      [_registry, node_spec] = children
      assert node_spec.id == {VeriSim.Consensus.KRaftNode, "n1"}
    end

    test "three configured nodes yield Registry + three KRaftNode specs" do
      {:ok, {_flags, children}} =
        KRaftSupervisor.init(
          nodes: [
            [node_id: "a", peers: ["b", "c"]],
            [node_id: "b", peers: ["a", "c"]],
            [node_id: "c", peers: ["a", "b"]]
          ]
        )

      assert length(children) == 4

      [_registry | node_specs] = children
      node_ids = Enum.map(node_specs, & &1.id)
      assert {VeriSim.Consensus.KRaftNode, "a"} in node_ids
      assert {VeriSim.Consensus.KRaftNode, "b"} in node_ids
      assert {VeriSim.Consensus.KRaftNode, "c"} in node_ids
    end

    test "child IDs are unique per node so the supervisor can manage them" do
      {:ok, {_flags, children}} =
        KRaftSupervisor.init(
          nodes: [
            [node_id: "x", peers: []],
            [node_id: "y", peers: []],
            [node_id: "z", peers: []]
          ]
        )

      ids = Enum.map(children, & &1.id)
      assert length(ids) == length(Enum.uniq(ids))
    end
  end

  describe "missing :node_id" do
    test "raises KeyError when a node opts is missing :node_id" do
      assert_raise KeyError, fn ->
        KRaftSupervisor.init(nodes: [[peers: ["other"]]])
      end
    end
  end
end
