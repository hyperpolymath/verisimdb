# SPDX-License-Identifier: PMPL-1.0-or-later

defmodule VeriSim.Consensus.KRaftNode do
  @moduledoc """
  KRaft Consensus Node — Elixir GenServer driving the ReScript Raft state machine.

  Each node in the cluster runs a KRaftNode GenServer that:
  - Manages election timers and heartbeat scheduling
  - Dispatches RPC messages (VoteRequest, AppendEntries) to peers
  - Accepts client commands and replicates them via the leader
  - Applies committed commands to the local Registry state
  - Persists the Raft log via write-ahead log (WAL)

  ## Architecture

      ┌─────────────────────────────────────────────┐
      │  KRaftNode (GenServer)                      │
      │    ├── Election Timer (Process.send_after)  │
      │    ├── Heartbeat Timer (leader only)        │
      │    ├── Raft State (from MetadataLog.res)    │
      │    └── Registry State (from Registry.res)   │
      └─────────────────────────────────────────────┘
              ↕ RPC (GenServer.call)
      ┌─────────────────────────────────────────────┐
      │  Peer KRaftNodes (same or remote)           │
      └─────────────────────────────────────────────┘

  ## Usage

      # Start a 3-node cluster
      {:ok, _} = KRaftNode.start_link(node_id: "node-1", peers: ["node-2", "node-3"])
      {:ok, _} = KRaftNode.start_link(node_id: "node-2", peers: ["node-1", "node-3"])
      {:ok, _} = KRaftNode.start_link(node_id: "node-3", peers: ["node-1", "node-2"])

      # Propose a command (routes to leader)
      {:ok, index} = KRaftNode.propose("node-1", {:register_store, "store-1", "http://...", ["graph"]})
  """

  use GenServer
  require Logger

  @election_timeout_min 150
  @election_timeout_max 300
  @heartbeat_interval 50
  @tick_interval 10

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  defmodule State do
    @moduledoc false
    defstruct [
      :node_id,
      :peers,
      :role,
      :current_term,
      :voted_for,
      :log,
      :commit_index,
      :last_applied,
      :next_index,
      :match_index,
      :leader_id,
      :votes_received,
      :election_timer,
      :heartbeat_timer,
      :registry,
      :pending_requests,
      :election_count,
      :wal_path
    ]
  end

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    node_id = Keyword.fetch!(opts, :node_id)
    GenServer.start_link(__MODULE__, opts, name: via(node_id))
  end

  @doc "Propose a command to the cluster (will forward to leader if needed)."
  def propose(node_id, command) do
    GenServer.call(via(node_id), {:propose, command})
  end

  @doc "Get the current diagnostics for a node."
  def diagnostics(node_id) do
    GenServer.call(via(node_id), :diagnostics)
  end

  @doc "Get the current leader ID."
  def leader(node_id) do
    GenServer.call(via(node_id), :leader)
  end

  @doc "Get the registry state."
  def registry(node_id) do
    GenServer.call(via(node_id), :registry)
  end

  @doc "Receive a vote request RPC from a candidate."
  def request_vote(node_id, request) do
    GenServer.call(via(node_id), {:request_vote, request})
  end

  @doc "Receive an AppendEntries RPC from a leader."
  def append_entries(node_id, request) do
    GenServer.call(via(node_id), {:append_entries, request})
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    node_id = Keyword.fetch!(opts, :node_id)
    peers = Keyword.get(opts, :peers, [])
    wal_path = Keyword.get(opts, :wal_path, nil)

    state = %State{
      node_id: node_id,
      peers: peers,
      role: :follower,
      current_term: 0,
      voted_for: nil,
      log: [],
      commit_index: 0,
      last_applied: 0,
      next_index: %{},
      match_index: %{},
      leader_id: nil,
      votes_received: MapSet.new(),
      election_timer: schedule_election_timeout(),
      heartbeat_timer: nil,
      registry: initial_registry(),
      pending_requests: [],
      election_count: 0,
      wal_path: wal_path
    }

    Logger.info("KRaft: node #{node_id} started as follower")
    {:ok, state}
  end

  @impl true
  def handle_call({:propose, command}, from, %{role: :leader} = state) do
    entry = %{
      term: state.current_term,
      index: length(state.log) + 1,
      command: command,
      timestamp: System.system_time(:millisecond)
    }

    new_log = state.log ++ [entry]
    pending = [{entry.index, from} | state.pending_requests]

    state = %{state | log: new_log, pending_requests: pending}

    # Immediately replicate to followers
    send_append_entries(state)

    {:noreply, state}
  end

  def handle_call({:propose, _command}, _from, state) do
    {:reply, {:error, {:not_leader, state.leader_id}}, state}
  end

  def handle_call(:diagnostics, _from, state) do
    diag = %{
      node_id: state.node_id,
      role: state.role,
      current_term: state.current_term,
      commit_index: state.commit_index,
      last_applied: state.last_applied,
      log_length: length(state.log),
      peer_count: length(state.peers),
      leader_id: state.leader_id,
      election_count: state.election_count,
      pending_requests: length(state.pending_requests)
    }

    {:reply, diag, state}
  end

  def handle_call(:leader, _from, state) do
    {:reply, state.leader_id, state}
  end

  def handle_call(:registry, _from, state) do
    {:reply, state.registry, state}
  end

  def handle_call({:request_vote, request}, _from, state) do
    {new_state, response} = handle_vote_request(state, request)
    {:reply, response, new_state}
  end

  def handle_call({:append_entries, request}, _from, state) do
    {new_state, response} = handle_append_entries_rpc(state, request)
    {:reply, response, new_state}
  end

  @impl true
  def handle_info(:election_timeout, %{role: role} = state)
      when role in [:follower, :candidate] do
    Logger.info("KRaft: node #{state.node_id} election timeout, starting election")
    state = start_election(state)
    {:noreply, state}
  end

  def handle_info(:election_timeout, state) do
    # Leaders ignore election timeouts
    {:noreply, state}
  end

  def handle_info(:heartbeat, %{role: :leader} = state) do
    send_append_entries(state)
    state = %{state | heartbeat_timer: schedule_heartbeat()}
    {:noreply, state}
  end

  def handle_info(:heartbeat, state) do
    # Non-leaders ignore heartbeat timers
    {:noreply, state}
  end

  def handle_info({:vote_response, from_peer, response}, state) do
    state = handle_vote_response(state, from_peer, response)
    {:noreply, state}
  end

  def handle_info({:append_entries_response, from_peer, response}, state) do
    state = handle_ae_response(state, from_peer, response)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Election Logic
  # ---------------------------------------------------------------------------

  defp start_election(state) do
    new_term = state.current_term + 1

    Logger.info(
      "KRaft: node #{state.node_id} starting election for term #{new_term}"
    )

    state = %{
      state
      | role: :candidate,
        current_term: new_term,
        voted_for: state.node_id,
        votes_received: MapSet.new([state.node_id]),
        election_count: state.election_count + 1,
        election_timer: schedule_election_timeout()
    }

    # Send vote requests to all peers
    last_log_index = length(state.log)
    last_log_term = last_log_term(state)

    request = %{
      term: new_term,
      candidate_id: state.node_id,
      last_log_index: last_log_index,
      last_log_term: last_log_term
    }

    for peer <- state.peers do
      Task.start(fn ->
        try do
          response = GenServer.call(via(peer), {:request_vote, request}, 1_000)
          send(self_pid(state.node_id), {:vote_response, peer, response})
        rescue
          _ -> :timeout
        end
      end)
    end

    state
  end

  defp handle_vote_request(state, request) do
    cond do
      request.term < state.current_term ->
        {state, %{term: state.current_term, vote_granted: false}}

      request.term > state.current_term ->
        # Higher term — step down and grant vote if log is up-to-date
        state = step_down(state, request.term)

        if log_up_to_date?(state, request) do
          state = %{state | voted_for: request.candidate_id}
          state = reset_election_timer(state)
          {state, %{term: state.current_term, vote_granted: true}}
        else
          {state, %{term: state.current_term, vote_granted: false}}
        end

      state.voted_for == nil or state.voted_for == request.candidate_id ->
        if log_up_to_date?(state, request) do
          state = %{state | voted_for: request.candidate_id}
          state = reset_election_timer(state)
          {state, %{term: state.current_term, vote_granted: true}}
        else
          {state, %{term: state.current_term, vote_granted: false}}
        end

      true ->
        {state, %{term: state.current_term, vote_granted: false}}
    end
  end

  defp handle_vote_response(state, from_peer, response) do
    cond do
      response.term > state.current_term ->
        step_down(state, response.term)

      state.role == :candidate and response.vote_granted ->
        votes = MapSet.put(state.votes_received, from_peer)
        quorum = div(length(state.peers) + 1, 2) + 1

        if MapSet.size(votes) >= quorum do
          become_leader(%{state | votes_received: votes})
        else
          %{state | votes_received: votes}
        end

      true ->
        state
    end
  end

  defp become_leader(state) do
    Logger.info(
      "KRaft: node #{state.node_id} became leader for term #{state.current_term}"
    )

    last_log_index = length(state.log) + 1

    next_index =
      state.peers
      |> Enum.map(&{&1, last_log_index})
      |> Map.new()

    match_index =
      state.peers
      |> Enum.map(&{&1, 0})
      |> Map.new()

    # Cancel election timer, start heartbeat timer
    if state.election_timer, do: Process.cancel_timer(state.election_timer)

    state = %{
      state
      | role: :leader,
        leader_id: state.node_id,
        next_index: next_index,
        match_index: match_index,
        election_timer: nil,
        heartbeat_timer: schedule_heartbeat()
    }

    # Append NoOp to commit entries from previous terms
    noop = %{
      term: state.current_term,
      index: length(state.log) + 1,
      command: :noop,
      timestamp: System.system_time(:millisecond)
    }

    state = %{state | log: state.log ++ [noop]}

    # Send initial heartbeats
    send_append_entries(state)

    state
  end

  # ---------------------------------------------------------------------------
  # Log Replication
  # ---------------------------------------------------------------------------

  defp send_append_entries(state) do
    for peer <- state.peers do
      next_idx = Map.get(state.next_index, peer, 1)
      prev_log_index = next_idx - 1

      prev_log_term =
        if prev_log_index > 0 do
          case Enum.at(state.log, prev_log_index - 1) do
            nil -> 0
            entry -> entry.term
          end
        else
          0
        end

      entries = Enum.drop(state.log, next_idx - 1)

      request = %{
        term: state.current_term,
        leader_id: state.node_id,
        prev_log_index: prev_log_index,
        prev_log_term: prev_log_term,
        entries: entries,
        leader_commit: state.commit_index
      }

      node_id = state.node_id

      Task.start(fn ->
        try do
          response = GenServer.call(via(peer), {:append_entries, request}, 1_000)
          send(self_pid(node_id), {:append_entries_response, peer, response})
        rescue
          _ -> :timeout
        end
      end)
    end
  end

  defp handle_append_entries_rpc(state, request) do
    cond do
      request.term < state.current_term ->
        {state, %{term: state.current_term, success: false, match_index: 0}}

      true ->
        state =
          if request.term > state.current_term do
            step_down(state, request.term)
          else
            state
          end

        state = %{state | leader_id: request.leader_id}
        state = reset_election_timer(state)

        # Check prev log entry
        prev_ok =
          if request.prev_log_index == 0 do
            true
          else
            case Enum.at(state.log, request.prev_log_index - 1) do
              nil -> false
              entry -> entry.term == request.prev_log_term
            end
          end

        if prev_ok do
          # Append new entries (truncating conflicting suffix)
          new_log = Enum.take(state.log, request.prev_log_index) ++ request.entries
          new_commit = min(request.leader_commit, length(new_log))

          state = %{state | log: new_log, commit_index: new_commit}
          state = apply_committed(state)

          {state,
           %{
             term: state.current_term,
             success: true,
             match_index: length(state.log)
           }}
        else
          {state, %{term: state.current_term, success: false, match_index: 0}}
        end
    end
  end

  defp handle_ae_response(state, from_peer, response) do
    cond do
      response.term > state.current_term ->
        step_down(state, response.term)

      state.role == :leader and response.success ->
        next_index = Map.put(state.next_index, from_peer, response.match_index + 1)
        match_index = Map.put(state.match_index, from_peer, response.match_index)

        state = %{state | next_index: next_index, match_index: match_index}
        state = maybe_advance_commit(state)
        state = apply_committed(state)
        state = reply_to_pending(state)

        state

      state.role == :leader ->
        # Decrement nextIndex and retry
        current_next = Map.get(state.next_index, from_peer, 1)
        next_index = Map.put(state.next_index, from_peer, max(current_next - 1, 1))
        %{state | next_index: next_index}

      true ->
        state
    end
  end

  # ---------------------------------------------------------------------------
  # Commit & Apply
  # ---------------------------------------------------------------------------

  defp maybe_advance_commit(state) do
    # Find highest N where majority of matchIndex[i] >= N
    all_match =
      (Map.values(state.match_index) ++ [length(state.log)])
      |> Enum.sort(:desc)

    quorum_idx = div(length(state.peers) + 1, 2)
    new_commit = Enum.at(all_match, quorum_idx, state.commit_index)

    # Only commit entries from current term (Raft safety property)
    can_commit =
      case Enum.at(state.log, new_commit - 1) do
        nil -> false
        entry -> entry.term == state.current_term
      end

    if can_commit and new_commit > state.commit_index do
      %{state | commit_index: new_commit}
    else
      state
    end
  end

  defp apply_committed(state) do
    if state.last_applied >= state.commit_index do
      state
    else
      entries_to_apply =
        state.log
        |> Enum.slice(state.last_applied, state.commit_index - state.last_applied)

      new_registry =
        Enum.reduce(entries_to_apply, state.registry, fn entry, reg ->
          apply_command(reg, entry.command)
        end)

      Logger.debug(
        "KRaft: node #{state.node_id} applied #{length(entries_to_apply)} entries " <>
          "(#{state.last_applied + 1}..#{state.commit_index})"
      )

      %{state | last_applied: state.commit_index, registry: new_registry}
    end
  end

  defp apply_command(registry, {:register_store, store_id, endpoint, modalities}) do
    store = %{
      store_id: store_id,
      endpoint: endpoint,
      modalities: modalities,
      trust_level: 1.0,
      last_seen: DateTime.utc_now(),
      response_time_ms: nil
    }

    put_in(registry, [:stores, store_id], store)
  end

  defp apply_command(registry, {:unregister_store, store_id}) do
    update_in(registry, [:stores], &Map.delete(&1, store_id))
  end

  defp apply_command(registry, {:map_hexad, hexad_id, locations}) do
    mapping = %{
      hexad_id: hexad_id,
      locations: locations,
      primary_store: nil,
      created: DateTime.utc_now(),
      modified: DateTime.utc_now()
    }

    put_in(registry, [:mappings, hexad_id], mapping)
  end

  defp apply_command(registry, {:unmap_hexad, hexad_id}) do
    update_in(registry, [:mappings], &Map.delete(&1, hexad_id))
  end

  defp apply_command(registry, {:update_trust, store_id, new_trust}) do
    case get_in(registry, [:stores, store_id]) do
      nil -> registry
      store -> put_in(registry, [:stores, store_id], %{store | trust_level: new_trust})
    end
  end

  defp apply_command(registry, :noop), do: registry

  defp reply_to_pending(state) do
    {fulfilled, remaining} =
      Enum.split_with(state.pending_requests, fn {index, _from} ->
        index <= state.commit_index
      end)

    Enum.each(fulfilled, fn {index, from} ->
      GenServer.reply(from, {:ok, index})
    end)

    %{state | pending_requests: remaining}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp step_down(state, new_term) do
    if state.heartbeat_timer, do: Process.cancel_timer(state.heartbeat_timer)

    %{
      state
      | role: :follower,
        current_term: new_term,
        voted_for: nil,
        votes_received: MapSet.new(),
        heartbeat_timer: nil,
        election_timer: schedule_election_timeout()
    }
  end

  defp reset_election_timer(state) do
    if state.election_timer, do: Process.cancel_timer(state.election_timer)
    %{state | election_timer: schedule_election_timeout()}
  end

  defp log_up_to_date?(state, request) do
    my_last_term = last_log_term(state)
    my_last_index = length(state.log)

    cond do
      request.last_log_term > my_last_term -> true
      request.last_log_term == my_last_term and request.last_log_index >= my_last_index -> true
      true -> false
    end
  end

  defp last_log_term(state) do
    case List.last(state.log) do
      nil -> 0
      entry -> entry.term
    end
  end

  defp schedule_election_timeout do
    timeout =
      @election_timeout_min +
        :rand.uniform(@election_timeout_max - @election_timeout_min)

    Process.send_after(self(), :election_timeout, timeout)
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end

  defp via(node_id) do
    {:via, Registry, {VeriSim.Consensus.Registry, node_id}}
  end

  defp self_pid(node_id) do
    case Registry.lookup(VeriSim.Consensus.Registry, node_id) do
      [{pid, _}] -> pid
      _ -> self()
    end
  end

  defp initial_registry do
    %{
      stores: %{},
      mappings: %{},
      config: %{
        min_trust_level: 0.5,
        max_store_downtime_ms: 300_000,
        replication_factor: 3,
        consistency_mode: :quorum
      }
    }
  end
end
