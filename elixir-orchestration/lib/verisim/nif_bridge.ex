# SPDX-License-Identifier: MPL-2.0

defmodule VeriSim.NifBridge do
  @moduledoc """
  Compatibility tombstone for the retired conventional NIF transport.

  No native library is loaded, even when an old artifact remains in `priv`.
  Explicit `VERISIM_TRANSPORT=nif` requests fail closed. `http` remains the
  default, and `auto` continues through HTTP. Store I/O must stay host-side;
  future native compute requires a measured SNIF kernel, Idris2 ABI and Zig FFI.
  """

  @doc "A retired transport can never be loaded."
  def load_nif, do: {:error, :nif_retired}

  def create_octad(_json_input), do: {:error, :nif_retired}
  def get_octad(_octad_id), do: {:error, :nif_retired}
  def delete_octad(_octad_id), do: {:error, :nif_retired}
  def search_text(_query, _limit), do: {:error, :nif_retired}
  def search_vector(_embedding_json, _k), do: {:error, :nif_retired}
  def list_octads(_limit, _offset), do: {:error, :nif_retired}
  def get_drift_score(_octad_id), do: {:error, :nif_retired}
  def trigger_normalise(_octad_id), do: {:error, :nif_retired}

  @doc "Conventional NIF transport is permanently non-operational."
  def loaded?, do: false
end
