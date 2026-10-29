# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule VeriSim.Query.VCLTGate do
  @moduledoc """
  VCL-total gate integration (consumer half).

  When the `VERISIM_VCLT_GATE` environment variable is set to the path of
  the `vclt-gate` binary (from the vcl-ut repo), every VCL epistemic
  statement (INSPECT / VERIFY / SELECT) is checked for VCL-total
  admissibility **before** execution.  Inadmissible statements are rejected
  with reasons; gate errors fail closed.

  ## Fail-closed policy

  | Gate result   | Action                                   |
  |---------------|------------------------------------------|
  | :skip         | Gate not configured — proceed normally   |
  | :admit        | Gate exit 0 — proceed                    |
  | {:reject, rs} | Gate exit 1 — caller should return 422   |
  | {:error, ...} | Gate exit 2 / missing / timeout — block  |

  ## Mutations bypass the gate

  INSERT / UPDATE / DELETE mutations go through the proof-verification path
  (`VCLTypeChecker`/`verify_multi_proof`) instead.  The gate only runs for
  read/epistemic statements where VCL-total level safety matters.

  ## Binary protocol

  Invocation: `vclt-gate --input <path>`, where the file holds one JSON
  object, UTF-8, no length prefix. The file lives in a private 0o700
  directory created for the call and removed afterwards.
  Exit 0: admitted — JSON `{"certified_level": N, "levels": [...]}`
  Exit 1: rejected — JSON `{"certified_level": -1, "levels": [...]}`
  Exit 2: internal gate error (treat as gate failure).

  See `vcl-ut/docs/vclt-gate-contract.adoc` for the full spec.
  """

  require Logger

  @gate_timeout_ms 5_000

  @doc """
  Check a VCL statement against the vclt-gate binary.

  `schema` is an optional map following the OctadSchema JSON encoding
  defined in `vclt-gate-contract.adoc`.  Pass `%{}` if no schema is
  known; the gate will operate in schema-free mode (L0–L4 only).

  Returns:
  - `:skip` — `VERISIM_VCLT_GATE` not set; caller must proceed normally
  - `:admit` — gate admitted the statement (exit 0)
  - `{:reject, reasons}` — gate rejected the statement (exit 1); `reasons`
    is a non-empty list of human-readable strings
  - `{:error, :gate_failed}` — gate unavailable or timed out; fail closed
  """
  @spec check(String.t(), map()) ::
          :skip | :admit | {:reject, [String.t()]} | {:error, :gate_failed}
  def check(statement, schema \\ %{}) do
    case gate_path() do
      nil -> :skip
      path -> run_gate(path, statement, schema)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp gate_path do
    case System.get_env("VERISIM_VCLT_GATE") do
      nil -> nil
      "" -> nil
      path -> path
    end
  end

  defp run_gate(path, statement, schema) do
    payload =
      Jason.encode!(%{
        "schema_version" => 1,
        "statement" => statement,
        "schema" => schema
      })

    case write_request(payload) do
      {:ok, dir, request} ->
        # The caller owns the request file, not the task: a timed-out task is
        # brutally killed, so cleanup inside it would never run.
        try do
          await_gate(path, request)
        after
          File.rm_rf(dir)
        end

      {:error, reason} ->
        Logger.warning("vclt-gate: cannot write request (#{inspect(reason)}) — failing closed")
        {:error, :gate_failed}
    end
  end

  defp await_gate(path, request) do
    task = Task.async(fn -> invoke_gate(path, request) end)

    case Task.yield(task, @gate_timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        Logger.warning("vclt-gate: timed out after #{@gate_timeout_ms}ms — failing closed")
        {:error, :gate_failed}
    end
  end

  # The request goes in a file because `System.cmd/3` cannot write a child's
  # stdin (it has no `:input` option, and an Erlang port cannot half-close
  # stdin to signal EOF), so the gate's `--input <path>` transport is the one
  # this side can use (vcl-ut `docs/vclt-gate-contract.adoc` §"Transport").
  #
  # The file sits in a fresh directory that `mkdir` creates exclusively and
  # that is narrowed to 0o700 before the payload exists. Erlang cannot open a
  # file with a mode, so a file created directly in the shared temp directory
  # would be readable under the umask until a `chmod`, and a reader that
  # opened it in that window would keep its descriptor. A directory has no
  # such window: its mode is checked on every lookup inside it.
  defp write_request(payload, attempts \\ 3)

  defp write_request(_payload, 0), do: {:error, :no_unique_name}

  defp write_request(payload, attempts) do
    name = "vclt-gate-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    dir = Path.join(System.tmp_dir!(), name)
    request = Path.join(dir, "request.json")

    case File.mkdir(dir) do
      :ok ->
        with :ok <- File.chmod(dir, 0o700),
             :ok <- File.write(request, payload, [:exclusive]),
             :ok <- File.chmod(request, 0o600) do
          {:ok, dir, request}
        else
          {:error, reason} ->
            File.rm_rf(dir)
            {:error, reason}
        end

      {:error, :eexist} ->
        write_request(payload, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    # `System.tmp_dir!/0` raises when no temp directory is writable.
    e -> {:error, Exception.message(e)}
  end

  defp invoke_gate(path, request) do
    try do
      # No shell: `path` is the executable and `--input` and `request` are
      # argv entries, never shell words, so neither `VERISIM_VCLT_GATE` nor the
      # statement can smuggle metacharacters. `System.cmd/3` raises
      # `ErlangError` when the executable is missing or not runnable; the
      # `rescue` turns that into the documented fail-closed result.
      {output, exit_code} = System.cmd(path, ["--input", request], stderr_to_stdout: false)

      handle_gate_result(output, exit_code)
    rescue
      e ->
        Logger.warning("vclt-gate: invocation error: #{Exception.message(e)} — failing closed")
        {:error, :gate_failed}
    end
  end

  defp handle_gate_result(output, 0) do
    case Jason.decode(output) do
      {:ok, %{"certified_level" => level}} ->
        Logger.debug("vclt-gate: admitted at level #{level}")
        :admit

      _ ->
        Logger.debug("vclt-gate: exit 0 (admitted, no level detail)")
        :admit
    end
  end

  defp handle_gate_result(output, 1) do
    reasons = extract_reasons(output)
    Logger.info("vclt-gate: rejected — #{Enum.join(reasons, "; ")}")
    {:reject, reasons}
  end

  defp handle_gate_result(_output, code) do
    Logger.warning("vclt-gate: exit #{code} — failing closed")
    {:error, :gate_failed}
  end

  defp extract_reasons(output) do
    case Jason.decode(output) do
      {:ok, %{"levels" => levels}} when is_list(levels) ->
        failed =
          levels
          |> Enum.filter(fn l -> l["status"] == "fail" end)
          |> Enum.map(fn l ->
            "#{l["name"]} (L#{l["level"]}): #{l["reason"] || "rejected"}"
          end)

        if failed == [], do: ["inadmissible (no detail)"], else: failed

      {:ok, %{"error" => msg}} ->
        ["#{msg}"]

      _ ->
        ["inadmissible (gate response unparseable: #{String.slice(output, 0, 100)})"]
    end
  end
end
