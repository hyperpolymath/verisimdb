# SPDX-License-Identifier: PMPL-1.0-or-later

defmodule VeriSim.RustClient do
  @moduledoc """
  HTTP client for communicating with the Rust core (verisim-api).

  This module provides a typed interface to the Rust HTTP API,
  handling serialization, error handling, and retries.
  """

  require Logger

  @default_base_url "http://localhost:8080/api/v1"
  @default_timeout 30_000

  # Configuration

  def base_url do
    Application.get_env(:verisim, :rust_core_url, @default_base_url)
  end

  def timeout do
    Application.get_env(:verisim, :rust_core_timeout, @default_timeout)
  end

  # Health Check

  @doc """
  Check the health of the Rust core.
  """
  def health do
    case get("/health") do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}
      {:ok, %{status: status}} ->
        {:error, {:unhealthy, status}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Hexad Operations

  @doc """
  Create a new hexad entity.
  """
  def create_hexad(input) do
    case post("/hexads", input) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 201, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get a hexad by ID.
  """
  def get_hexad(entity_id) do
    case get("/hexads/#{entity_id}") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Update a hexad.
  """
  def update_hexad(entity_id, changes) do
    case put("/hexads/#{entity_id}", changes) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete a hexad.
  """
  def delete_hexad(entity_id) do
    case delete("/hexads/#{entity_id}") do
      {:ok, %{status: 204}} -> :ok
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Search Operations

  @doc """
  Search for hexads by text.
  """
  def search_text(query, limit \\ 10) do
    case get("/search/text", q: query, limit: limit) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Search for hexads by vector similarity.
  """
  def search_vector(vector, k \\ 10) do
    case post("/search/vector", %{vector: vector, k: k}) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get related hexads (graph query).
  """
  def get_related(entity_id) do
    case get("/search/related/#{entity_id}") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Drift and Normalization

  @doc """
  Get the drift score for an entity.
  """
  def get_drift_score(entity_id) do
    case get("/drift/entity/#{entity_id}") do
      {:ok, %{status: 200, body: %{"score" => score}}} -> {:ok, score}
      {:ok, %{status: 404}} -> {:ok, 0.0}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get overall drift status.
  """
  def drift_status do
    case get("/drift/status") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Trigger normalization for an entity.
  """
  def normalize(entity_id) do
    case post("/normalizer/trigger/#{entity_id}", %{}) do
      {:ok, %{status: 202}} -> :ok
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get normalizer status.
  """
  def normalizer_status do
    case get("/normalizer/status") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Private HTTP Helpers

  defp get(path, params \\ []) do
    url = base_url() <> path

    Req.get(url,
      params: params,
      receive_timeout: timeout(),
      decode_body: true
    )
  rescue
    e -> {:error, {:request_failed, e}}
  end

  defp post(path, body) do
    url = base_url() <> path

    Req.post(url,
      json: body,
      receive_timeout: timeout(),
      decode_body: true
    )
  rescue
    e -> {:error, {:request_failed, e}}
  end

  defp put(path, body) do
    url = base_url() <> path

    Req.put(url,
      json: body,
      receive_timeout: timeout(),
      decode_body: true
    )
  rescue
    e -> {:error, {:request_failed, e}}
  end

  defp delete(path) do
    url = base_url() <> path

    Req.delete(url,
      receive_timeout: timeout(),
      decode_body: true
    )
  rescue
    e -> {:error, {:request_failed, e}}
  end
end
