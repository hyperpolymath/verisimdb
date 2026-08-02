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

  Standard input: one JSON object, UTF-8, no length prefix.
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

    task = Task.async(fn -> invoke_gate(path, payload) end)

    case Task.yield(task, @gate_timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        Logger.warning("vclt-gate: timed out after #{@gate_timeout_ms}ms — failing closed")
        {:error, :gate_failed}
    end
  end

  defp invoke_gate(path, payload) do
    # Write the JSON payload to a temp file and redirect it to the gate's stdin
    # via the shell.  The path comes from an operator-controlled env var, so
    # quoting it is sufficient.
    tmp =
      Path.join(
        System.tmp_dir!(),
        "vcltgate_#{:erlang.unique_integer([:positive])}.json"
      )

    try do
      File.write!(tmp, payload)

      # Quote path and tmp — no user-supplied values reach the shell here.
      quoted_path = shell_quote(path)
      quoted_tmp = shell_quote(tmp)

      {output, exit_code} =
        System.cmd("sh", ["-c", "#{quoted_path} < #{quoted_tmp}"], stderr_to_stdout: false)

      handle_gate_result(IO.iodata_to_binary(output), exit_code)
    rescue
      e ->
        Logger.warning("vclt-gate: invocation error: #{Exception.message(e)} — failing closed")
        {:error, :gate_failed}
    after
      File.rm(tmp)
    end
  end

  defp shell_quote(str), do: "'" <> String.replace(str, "'", "'\\''") <> "'"

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
