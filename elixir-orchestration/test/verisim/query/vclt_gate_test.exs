# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule VeriSim.Query.VCLTGateTest do
  use ExUnit.Case, async: true

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
end
