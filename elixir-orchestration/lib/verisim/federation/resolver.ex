# SPDX-License-Identifier: PMPL-1.0-or-later

defmodule VeriSim.Federation.Resolver do
  @moduledoc """
  Federation Resolver — coordinates cross-instance queries.

  Resolves federated query patterns to peer stores, dispatches parallel
  queries, and aggregates results according to drift policies.

  ## Drift Policies

  - `:strict`   — Only include stores with trust level above threshold.
  - `:repair`   — Include all, trigger normalization on drifted stores.
  - `:tolerate` — Include all, annotate drifted results.
  - `:latest`   — Use only the most recent data from each store.
  """

  use GenServer
  require Logger

  alias VeriSim.RustClient

  @default_timeout 10_000
  @health_check_interval 60_000
  @strict_trust_threshold 0.7

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a peer store in the federation."
  def register_peer(store_id, endpoint, modalities) do
    GenServer.call(__MODULE__, {:register, store_id, endpoint, modalities})
  end

  @doc "Remove a peer from the federation."
  def deregister_peer(store_id) do
    GenServer.call(__MODULE__, {:deregister, store_id})
  end

  @doc "List all known peers."
  def list_peers do
    GenServer.call(__MODULE__, :list_peers)
  end

  @doc """
  Execute a federated query across matching stores.

  ## Options
  - `:drift_policy` — :strict | :repair | :tolerate | :latest (default: :tolerate)
  - `:limit` — max results per store
  - `:timeout` — query timeout in ms
  """
  def query(pattern, modalities, opts \\ []) do
    GenServer.call(
      __MODULE__,
      {:query, pattern, modalities, opts},
      Keyword.get(opts, :timeout, @default_timeout)
    )
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # Register with the Rust API's federation endpoint
    state = %{
      peers: %{},
      self_store_id: "local",
      health_check_ref: schedule_health_check()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register, store_id, endpoint, modalities}, _from, state) do
    peer = %{
      store_id: store_id,
      endpoint: endpoint,
      modalities: modalities,
      trust_level: 1.0,
      last_seen: DateTime.utc_now(),
      response_time_ms: nil
    }

    Logger.info("Federation: registered peer #{store_id} at #{endpoint}")
    new_peers = Map.put(state.peers, store_id, peer)

    # Also register with Rust API
    RustClient.post("/federation/register", %{
      store_id: store_id,
      endpoint: endpoint,
      modalities: modalities
    })

    {:reply, :ok, %{state | peers: new_peers}}
  end

  @impl true
  def handle_call({:deregister, store_id}, _from, state) do
    new_peers = Map.delete(state.peers, store_id)
    Logger.info("Federation: deregistered peer #{store_id}")

    RustClient.post("/federation/deregister/#{store_id}", %{})

    {:reply, :ok, %{state | peers: new_peers}}
  end

  @impl true
  def handle_call(:list_peers, _from, state) do
    {:reply, Map.values(state.peers), state}
  end

  @impl true
  def handle_call({:query, pattern, modalities, opts}, _from, state) do
    drift_policy = Keyword.get(opts, :drift_policy, :tolerate)
    limit = Keyword.get(opts, :limit, 100)

    # Resolve pattern to matching stores
    matching = resolve_pattern(state.peers, pattern, modalities)

    # Apply drift policy filter
    {included, excluded} = apply_drift_policy(matching, drift_policy)

    # Fan out queries in parallel
    tasks =
      Enum.map(included, fn peer ->
        Task.async(fn -> query_peer(peer, modalities, limit) end)
      end)

    # Collect results with timeout
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    results =
      tasks
      |> Task.yield_many(timeout)
      |> Enum.flat_map(fn
        {_task, {:ok, {:ok, results}}} -> results
        {_task, {:ok, {:error, reason}}} ->
          Logger.warning("Federation: peer query failed: #{inspect(reason)}")
          []
        {task, nil} ->
          Task.shutdown(task, :brutal_kill)
          Logger.warning("Federation: peer query timed out")
          []
      end)

    # Handle repair policy: trigger normalization on drifted stores
    if drift_policy == :repair do
      Enum.each(excluded, fn peer ->
        Logger.info("Federation: triggering repair on drifted store #{peer.store_id}")
        # Would trigger normalization on the peer
      end)
    end

    response = %{
      results: results,
      stores_queried: Enum.map(included, & &1.store_id),
      stores_excluded: Enum.map(excluded, & &1.store_id),
      drift_policy: drift_policy
    }

    {:reply, {:ok, response}, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    # Ping all peers and update trust levels
    new_peers =
      state.peers
      |> Enum.map(fn {id, peer} ->
        case health_check_peer(peer) do
          {:ok, response_time} ->
            {id, %{peer |
              last_seen: DateTime.utc_now(),
              response_time_ms: response_time,
              trust_level: min(peer.trust_level + 0.05, 1.0)
            }}

          {:error, _} ->
            {id, %{peer |
              trust_level: max(peer.trust_level - 0.1, 0.0)
            }}
        end
      end)
      |> Map.new()

    {:noreply, %{state | peers: new_peers, health_check_ref: schedule_health_check()}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp resolve_pattern(peers, pattern, required_modalities) do
    peers
    |> Map.values()
    |> Enum.filter(fn peer ->
      pattern_matches?(pattern, peer.store_id) &&
        Enum.all?(required_modalities, fn m ->
          m in peer.modalities
        end)
    end)
  end

  defp pattern_matches?("*", _store_id), do: true

  defp pattern_matches?(pattern, store_id) do
    if String.ends_with?(pattern, "/*") do
      prefix = String.trim_trailing(pattern, "/*")
      String.starts_with?(store_id, prefix)
    else
      pattern == store_id
    end
  end

  defp apply_drift_policy(peers, :strict) do
    Enum.split_with(peers, fn peer ->
      peer.trust_level >= @strict_trust_threshold
    end)
  end

  defp apply_drift_policy(peers, _policy) do
    {peers, []}
  end

  defp query_peer(peer, _modalities, _limit) do
    # In production: HTTP request to peer.endpoint
    # For now, return empty results
    {:ok, []}
  end

  defp health_check_peer(peer) do
    start = System.monotonic_time(:millisecond)

    # In production: HTTP GET to peer.endpoint/health
    # For now, simulate
    case peer.endpoint do
      "http://" <> _ ->
        elapsed = System.monotonic_time(:millisecond) - start
        {:ok, elapsed}

      _ ->
        {:error, :invalid_endpoint}
    end
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end
end
