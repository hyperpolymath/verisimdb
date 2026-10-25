# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule VeriSim.Query.VCLTGate do
  @moduledoc """
  Optional VCL-total admissibility gate for epistemic statements.

  `VERISIM_VCLT_GATE` selects a trusted local executable. An unset gate returns
  `:skip`; configured gates fail closed on invocation, protocol or budget errors.
  The gate receives a schema-version-1 JSON object through `--input`. Exit 0 requires a
  valid certification response; exit 1 rejects; any other status blocks.

  Elixir 1.17 has no `System.cmd/3` stdin option. The producer's v1 contract
  provides an equivalent `--input PATH` transport. A private temporary file
  supplies the request; no shell parses either paths or payloads.
  GNU coreutils `timeout` bounds execution to five seconds, killing the process
  group on expiry. Input is limited to 1 MiB and collected stdout to 64 KiB.
  Missing `timeout` fails closed. This is host process I/O, not a SNIF.
  """

  require Logger

  @gate_timeout_ms 5_000
  @max_input_bytes 1_048_576
  @max_output_bytes 65_536

  @doc """
  Check a statement with the executable selected by `VERISIM_VCLT_GATE`.

  `schema` is the optional OctadSchema map sent with the statement in the
  version-1 JSON request; it defaults to `%{}`. See
  `vcl-ut/docs/vclt-gate-contract.adoc` for the schema format.

  Returns `:skip` when the environment variable is unset or empty, or `:admit`
  for exit 0 with a valid certification response. Exit 1 returns
  `{:reject, reasons}` with a non-empty list of strings, falling back to
  `"inadmissible (no detail)"` when the response has no usable failure details.

  Invocation and encoding exceptions, invalid success responses, other exit
  statuses, timeouts and exceeded size limits return `{:error, :gate_failed}`.
  The encoded request may contain at most 1 MiB and stdout at most 64 KiB.
  Execution requires GNU `timeout` and is limited to five seconds, with a
  further 500 ms allowed for collecting the result.

  A configured gate receives the request through `--input` in a private
  temporary file; cleanup is attempted after invocation, including on failure.
  """
  @spec check(String.t(), map()) ::
          :skip | :admit | {:reject, [String.t()]} | {:error, :gate_failed}
  def check(statement, schema \\ %{}) do
    case System.get_env("VERISIM_VCLT_GATE") do
      path when path in [nil, ""] -> :skip
      path -> run_gate(path, statement, schema)
    end
  end

  defp run_gate(path, statement, schema) do
    payload = Jason.encode!(%{schema_version: 1, statement: statement, schema: schema})

    if byte_size(payload) > @max_input_bytes do
      {:error, :gate_failed}
    else
      directory =
        Path.join(
          System.tmp_dir!(),
          "vcltgate_" <> Base.url_encode64(:crypto.strong_rand_bytes(24))
        )

      # mkdir is exclusive. No payload is written until the directory is private.
      File.mkdir!(directory)

      try do
        File.chmod!(directory, 0o700)
        input = Path.join(directory, "input.json")
        File.write!(input, payload, [:exclusive])
        File.chmod!(input, 0o600)
        invoke_gate(path, input)
      after
        File.rm_rf(directory)
      end
    end
  rescue
    _ ->
      # Do not log the exception: encoders and argument errors can include input.
      Logger.warning("vclt-gate: invocation or encoding failed — failing closed")
      {:error, :gate_failed}
  end

  defp invoke_gate(path, input) do
    timeout = System.find_executable("timeout") || raise "GNU timeout is required"

    port =
      Port.open({:spawn_executable, timeout}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        args: [
          "--signal=KILL",
          "#{@gate_timeout_ms / 1000}s",
          Path.expand(path),
          "--input",
          input
        ]
      ])

    try do
      collect(port, [], 0, System.monotonic_time(:millisecond) + @gate_timeout_ms + 500)
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp collect(port, chunks, size, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        if size + byte_size(data) > @max_output_bytes do
          {:error, :gate_failed}
        else
          collect(port, [data | chunks], size + byte_size(data), deadline)
        end

      {^port, {:exit_status, code}} ->
        handle_gate_result(chunks |> Enum.reverse() |> IO.iodata_to_binary(), code)
    after
      remaining -> {:error, :gate_failed}
    end
  end

  defp handle_gate_result(output, 0) do
    case Jason.decode(output) do
      {:ok,
       %{
         "schema_version" => 1,
         "admissible" => true,
         "requested_level" => level,
         "certified_level" => level,
         "levels" => levels
       }}
      when is_integer(level) and level >= 0 and level <= 10 and is_list(levels) ->
        if Enum.all?(levels, &(is_map(&1) and &1["status"] == "pass")),
          do: :admit,
          else: {:error, :gate_failed}

      _ ->
        {:error, :gate_failed}
    end
  end

  defp handle_gate_result(output, 1) do
    reasons =
      case Jason.decode(output) do
        {:ok, %{"levels" => levels}} when is_list(levels) ->
          for %{"status" => "fail", "name" => name, "level" => level} = result <- levels,
              is_binary(name) and is_integer(level) do
            reason = if is_binary(result["reason"]), do: result["reason"], else: "rejected"
            "#{name} (L#{level}): #{reason}"
          end

        _ ->
          []
      end

    {:reject, if(reasons == [], do: ["inadmissible (no detail)"], else: reasons)}
  end

  defp handle_gate_result(_output, _code), do: {:error, :gate_failed}
end
