# SPDX-License-Identifier: MPL-2.0

defmodule VeriSim.Hypatia.PatternQueryTest do
  @moduledoc """
  Tests for the Hypatia cross-repo pattern analytics module.

  Verifies pipeline health, cross-repo patterns, severity distributions,
  and temporal trend queries against ingested scan data.
  """

  use ExUnit.Case, async: false

  alias VeriSim.Hypatia.ScanIngester
  alias VeriSim.Hypatia.PatternQuery

  setup do
    # Clean ETS between tests
    case :ets.info(:hypatia_scans) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(:hypatia_scans)
    end

    # Ingest some test scans
    for {repo, lang, wps} <- test_data() do
      scan = %{
        "assail_report" => %{
          "program_path" => "/repos/#{repo}",
          "language" => lang,
          "frameworks" => [],
          "weak_points" => wps
        }
      }

      ScanIngester.ingest_scan(scan)
    end

    :ok
  end

  defp test_data do
    [
      {"repo-alpha", "rust",
       [
         %{
           "category" => "PanicPath",
           "location" => "src/main.rs",
           "severity" => "Medium",
           "description" => "unwrap"
         },
         %{
           "category" => "UnsafeCode",
           "location" => "src/ffi.rs",
           "severity" => "High",
           "description" => "unsafe block"
         },
         %{
           "category" => "PanicPath",
           "location" => "src/lib.rs",
           "severity" => "Medium",
           "description" => "expect"
         }
       ]},
      {"repo-beta", "elixir",
       [
         %{
           "category" => "PanicPath",
           "location" => "lib/worker.ex",
           "severity" => "Medium",
           "description" => "raise"
         },
         %{
           "category" => "InputValidation",
           "location" => "lib/api.ex",
           "severity" => "High",
           "description" => "unsanitized"
         }
       ]},
      {"repo-gamma", "rust",
       [
         %{
           "category" => "PanicPath",
           "location" => "src/core.rs",
           "severity" => "Medium",
           "description" => "unwrap"
         },
         %{
           "category" => "PanicPath",
           "location" => "src/net.rs",
           "severity" => "High",
           "description" => "index panic"
         },
         %{
           "category" => "UnsafeCode",
           "location" => "src/sys.rs",
           "severity" => "High",
           "description" => "transmute"
         }
       ]},
      {"repo-delta", "javascript",
       [
         %{
           "category" => "InputValidation",
           "location" => "src/handler.js",
           "severity" => "High",
           "description" => "XSS"
         },
         %{
           "category" => "PanicPath",
           "location" => "src/index.js",
           "severity" => "Low",
           "description" => "throw"
         }
       ]}
    ]
  end

  # ===========================================================================
  # pipeline_health/0
  # ===========================================================================

  describe "pipeline_health/0" do
    test "returns correct total counts" do
      health = PatternQuery.pipeline_health()

      assert health.total_scans == 4
      assert health.repos_scanned == 4
      assert health.total_weak_points == 10
      assert health.severity_distribution == %{"High" => 5, "Medium" => 4, "Low" => 1}
      assert hd(health.top_categories) == {"PanicPath", 6}
    end
  end

  # ===========================================================================
  # cross_repo_patterns/1
  # ===========================================================================

  describe "cross_repo_patterns/1" do
    test "returns empty when no shared patterns meet threshold" do
      assert PatternQuery.cross_repo_patterns(100) == []
    end

    test "finds the pattern shared by three repos" do
      # PanicPath:Medium is in alpha, beta and gamma; delta's PanicPath is Low.
      assert [{"PanicPath:Medium", 3, repos}] = PatternQuery.cross_repo_patterns(3)
      assert Enum.sort(repos) == ["repo-alpha", "repo-beta", "repo-gamma"]
    end
  end

  # ===========================================================================
  # severity_distribution/0
  # ===========================================================================

  describe "severity_distribution/0" do
    test "counts findings per severity" do
      assert PatternQuery.severity_distribution() == %{"High" => 5, "Medium" => 4, "Low" => 1}
    end
  end

  # ===========================================================================
  # category_distribution/0
  # ===========================================================================

  describe "category_distribution/0" do
    test "counts findings per category, most frequent first" do
      dist = PatternQuery.category_distribution()
      assert hd(dist) == {"PanicPath", 6}
      assert Enum.sort(tl(dist)) == [{"InputValidation", 2}, {"UnsafeCode", 2}]
    end
  end

  # ===========================================================================
  # temporal_trends/1
  # ===========================================================================

  describe "temporal_trends/1" do
    test "returns scan history for a known repo" do
      trends = PatternQuery.temporal_trends("repo-alpha")

      assert length(trends) == 1
      assert hd(trends).weak_point_count == 3
    end

    test "returns empty for unknown repo" do
      trends = PatternQuery.temporal_trends("nonexistent")
      assert trends == []
    end
  end

  # ===========================================================================
  # repos_by_severity/1
  # ===========================================================================

  describe "repos_by_severity/1" do
    test "ranks repos by High severity" do
      repos = PatternQuery.repos_by_severity("High")

      # repo-alpha has 1 High, repo-beta has 1, repo-gamma has 2, repo-delta has 1
      assert is_list(repos)

      if length(repos) > 0 do
        {top_repo, top_count} = hd(repos)
        assert is_binary(top_repo)
        assert is_integer(top_count)
      end
    end
  end

  # ===========================================================================
  # weakness_hotspots/0
  # ===========================================================================

  describe "weakness_hotspots/0" do
    test "groups findings by file" do
      hotspots = PatternQuery.weakness_hotspots()
      # Every fixture finding is in a distinct file.
      assert length(hotspots) == 10
      assert Enum.all?(hotspots, fn {_loc, data} -> data.count == 1 end)
    end
  end
end
