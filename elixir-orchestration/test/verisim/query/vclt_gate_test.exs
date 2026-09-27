# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule VeriSim.Query.VCLTGateTest do
  # These tests mutate a process-global environment variable.
  use ExUnit.Case, async: false

  alias VeriSim.Query.VCLTGate

  describe "check/2 without gate configured" do
    test "returns :skip when VERISIM_VCLT_GATE is unset" do
      System.delete_env("VERISIM_VCLT_GATE")
      assert VCLTGate.check("SELECT GRAPH FROM HEXAD abc") == :skip
    end

    test "returns :skip when VERISIM_VCLT_GATE is empty string" do
      System.put_env("VERISIM_VCLT_GATE", "")
      assert VCLTGate.check("SELECT GRAPH FROM HEXAD abc") == :skip
    after
      System.delete_env("VERISIM_VCLT_GATE")
    end
  end

  describe "check/2 with a missing binary" do
    test "returns {:error, :gate_failed} when binary does not exist" do
      System.put_env("VERISIM_VCLT_GATE", "/nonexistent/vclt-gate")
      result = VCLTGate.check("SELECT GRAPH FROM HEXAD abc")
      assert {:error, :gate_failed} == result
    after
      System.delete_env("VERISIM_VCLT_GATE")
    end
  end

  describe "check/2 gate wiring via stub binaries" do
    @tag :tmp_dir
    test "returns :admit when stub exits 0 with valid JSON", %{tmp_dir: tmp} do
      stub = Path.join(tmp, "gate-admit")

      File.write!(stub, """
      #!/bin/sh
      echo '{"certified_level":6,"levels":[]}'
      exit 0
      """)

      File.chmod!(stub, 0o755)
      System.put_env("VERISIM_VCLT_GATE", stub)

      assert :admit == VCLTGate.check("INSPECT GRAPH FROM HEXAD abc LIMIT 1")
    after
      System.delete_env("VERISIM_VCLT_GATE")
    end

    @tag :tmp_dir
    test "delivers the payload on stdin, unparsed by any shell", %{tmp_dir: tmp} do
      stub = Path.join(tmp, "gate-stdin")
      observation = Path.join(tmp, "stdin-observation")

      # Copy stdin verbatim to a file so the test can assert on exactly what the
      # gate process received, then emit a valid admit response.
      File.write!(stub, """
      #!/bin/sh
      cat > #{shell_quote(observation)}
      echo '{"certified_level":6,"levels":[]}'
      exit 0
      """)

      File.chmod!(stub, 0o755)
      System.put_env("VERISIM_VCLT_GATE", stub)

      # Every character here is one a shell parser would act on: single quotes
      # (which would close an enclosing quote), `;` `|` `&` (separators), a
      # backtick and `$(...)` (command substitution), `>` (redirection), plus a
      # literal newline and tab in the schema value. If any part of the invocation
      # passed through a shell, at least one of these would be consumed, expanded
      # or split before reaching the gate.
      #
      # So asserting they survive byte-for-byte is a direct test of the property
      # that matters — no shell sees the statement or schema. That is strictly
      # stronger than what this test previously asserted (an unpredictable
      # `vcltgate_*.json` file at mode 600, removed afterwards), which described
      # the temp-file mechanism rather than the guarantee it existed to provide.
      # The mechanism is gone: `System.cmd/3`'s `:input` writes to stdin directly.
      hostile_statement =
        "INSPECT GRAPH FROM HEXAD abc WHERE id = '1' ; rm -rf / | x & `id` $(whoami) > /tmp/pwn"

      hostile_schema = %{"probe" => "' ; | & ` $( ) > \n tab\there"}

      assert :admit == VCLTGate.check(hostile_statement, hostile_schema)

      received = Jason.decode!(File.read!(observation))
      assert received["schema_version"] == 1
      assert received["statement"] == hostile_statement
      assert received["schema"] == hostile_schema
    after
      System.delete_env("VERISIM_VCLT_GATE")
    end

    @tag :tmp_dir
    test "returns {:reject, reasons} when stub exits 1 with level JSON", %{tmp_dir: tmp} do
      stub = Path.join(tmp, "gate-reject")

      File.write!(stub, """
      #!/bin/sh
      echo '{"certified_level":-1,"levels":[{"level":4,"name":"InjectionProof","status":"fail","reason":"SQL injection detected"}]}'
      exit 1
      """)

      File.chmod!(stub, 0o755)
      System.put_env("VERISIM_VCLT_GATE", stub)

      assert {:reject, reasons} =
               VCLTGate.check("SELECT * FROM HEXAD abc WHERE id = '1' OR '1'='1'")

      assert Enum.any?(reasons, &String.contains?(&1, "InjectionProof"))
    after
      System.delete_env("VERISIM_VCLT_GATE")
    end

    @tag :tmp_dir
    test "returns {:error, :gate_failed} when stub exits 2", %{tmp_dir: tmp} do
      stub = Path.join(tmp, "gate-error")

      File.write!(stub, """
      #!/bin/sh
      echo 'internal error' >&2
      exit 2
      """)

      File.chmod!(stub, 0o755)
      System.put_env("VERISIM_VCLT_GATE", stub)

      assert {:error, :gate_failed} == VCLTGate.check("SELECT GRAPH FROM HEXAD abc")
    after
      System.delete_env("VERISIM_VCLT_GATE")
    end
  end

  defp shell_quote(str), do: "'" <> String.replace(str, "'", "'\\''") <> "'"
end
