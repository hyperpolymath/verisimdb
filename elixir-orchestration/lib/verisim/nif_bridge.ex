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

  @doc "Returns `{:error, :nif_retired}` without creating an octad; the input is ignored."
  def create_octad(_json_input), do: {:error, :nif_retired}
  @doc "Returns `{:error, :nif_retired}` without retrieving an octad; the ID is ignored."
  def get_octad(_octad_id), do: {:error, :nif_retired}
  @doc "Returns `{:error, :nif_retired}` without deleting an octad; the ID is ignored."
  def delete_octad(_octad_id), do: {:error, :nif_retired}
  @doc "Returns `{:error, :nif_retired}` without searching; both arguments are ignored."
  def search_text(_query, _limit), do: {:error, :nif_retired}
  @doc "Returns `{:error, :nif_retired}` without searching; both arguments are ignored."
  def search_vector(_embedding_json, _k), do: {:error, :nif_retired}
  @doc "Returns `{:error, :nif_retired}` without listing octads; both arguments are ignored."
  def list_octads(_limit, _offset), do: {:error, :nif_retired}
  @doc "Returns `{:error, :nif_retired}` without measuring drift; the ID is ignored."
  def get_drift_score(_octad_id), do: {:error, :nif_retired}
  @doc "Returns `{:error, :nif_retired}` without triggering normalisation; the ID is ignored."
  def trigger_normalise(_octad_id), do: {:error, :nif_retired}

  @doc "Conventional NIF transport is permanently non-operational."
  def loaded?, do: false
end
