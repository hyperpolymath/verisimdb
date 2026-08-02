# SPDX-License-Identifier: MPL-2.0

defmodule VeriSim.NifBridge do
  @moduledoc """
  NIF bridge to the Rust core via Rustler.

  Provides direct in-process calls to VeriSimDB's Rust engine, bypassing HTTP
  for same-node deployments. When the NIF is loaded, operations execute ~10-100x
  faster than the HTTP transport.

  ## Loading

  The NIF shared library is loaded from `priv/native/libverisim_nif.so` (Linux)
  or `priv/native/libverisim_nif.dylib` (macOS). If the library is not present
  (e.g., in a pure-Elixir development setup), all functions return
  `{:error, :nif_not_loaded}`. If the library IS present but an operation is
  not yet wired to the store, that operation returns `{:error, :not_implemented}`
  — it never fabricates success. Today every operation is a not-implemented
  stub (see `rust-core/verisim-nif`), so the NIF is non-operational and `auto`
  transport always falls back to HTTP.

  ## Transport Selection

  This module is not called directly. Instead, `VeriSim.Transport` selects the
  transport based on `VERISIM_TRANSPORT`:

      VERISIM_TRANSPORT=http   # Default: HTTP via VeriSim.RustClient
      VERISIM_TRANSPORT=nif    # Direct NIF calls (this module)
      VERISIM_TRANSPORT=auto   # NIF if loaded, HTTP fallback

  ## Functions

  All functions accept and return JSON strings for compatibility with the HTTP
  transport (same serialisation format).
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    nif_path =
      :verisim
      |> :code.priv_dir()
      |> Path.join("native/libverisim_nif")

    case :erlang.load_nif(String.to_charlist(nif_path), 0) do
      :ok ->
        :ok

      # NIF not available — stubs will be used
      {:error, {:load_failed, _}} ->
        :ok

      # Already loaded
      {:error, {:reload, _}} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.debug("VeriSim.NifBridge: NIF not loaded (#{inspect(reason)})")
        :ok
    end
  end

  @doc """
  Create a new octad entity from a JSON string.

  Returns `{:ok, json}` on success, `{:error, reason}` on failure.
  """
  def create_octad(_json_input), do: {:error, :nif_not_loaded}

  @doc """
  Retrieve a octad by ID.

  Returns the full octad JSON with all 8 octad modalities.
  """
  def get_octad(_octad_id), do: {:error, :nif_not_loaded}

  @doc """
  Delete a octad entity by ID.
  """
  def delete_octad(_octad_id), do: {:error, :nif_not_loaded}

  @doc """
  Full-text search across the document modality.
  """
  def search_text(_query, _limit), do: {:error, :nif_not_loaded}

  @doc """
  Vector similarity search.

  Accepts a JSON-encoded embedding vector and a k parameter.
  """
  def search_vector(_embedding_json, _k), do: {:error, :nif_not_loaded}

  @doc """
  Paginated listing of octad entities.
  """
  def list_octads(_limit, _offset), do: {:error, :nif_not_loaded}

  @doc """
  Get drift detection scores for a specific entity.

  Returns drift scores across all 8 octad modalities.
  """
  def get_drift_score(_octad_id), do: {:error, :nif_not_loaded}

  @doc """
  Trigger normalisation (self-repair) for a drifted entity.
  """
  def trigger_normalise(_octad_id), do: {:error, :nif_not_loaded}

  @doc """
  Check whether the NIF bridge is loaded **and operational**.

  Returns `true` only when a probe operation returns a real result. Both the
  absent-library fallback (`{:error, :nif_not_loaded}`) and a loaded-but-
  unimplemented NIF (`{:error, :not_implemented}`) read as *not operational*,
  so `auto` transport never selects a NIF that cannot actually serve a
  request. When every operation is a not-implemented stub, this is `false`.
  """
  def loaded? do
    case get_octad("__health_check__") do
      result when is_binary(result) -> true
      _ -> false
    end
  end
end
