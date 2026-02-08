# VeriSimDB Integration Tasks - For Sonnet

**Context**: Opus has designed the architecture. These are the implementation tasks ready for execution.

**Priority**: High - this unblocks the panic-attack → verisimdb → hypatia → gitbot-fleet pipeline.

---

## Task 1: Create verisimdb-data Git-Backed Repo

**Estimated time**: 30 minutes

### Steps

1. Clone rsr-template-repo as starting point:
   ```bash
   cd ~/Documents/hyperpolymath-repos
   git clone https://github.com/hyperpolymath/rsr-template-repo verisimdb-data
   cd verisimdb-data
   rm -rf .git && git init -b main
   ```

2. Create directory structure:
   ```bash
   mkdir -p scans hardware drift
   touch index.json
   ```

3. Write initial `index.json`:
   ```json
   {
     "last_updated": "2026-02-08T00:00:00Z",
     "total_scans": 0,
     "repos": {}
   }
   ```

4. Update `README.adoc`:
   ```adoc
   = VeriSimDB Data Repository

   Git-backed flat-file storage for scan results and drift detection data.

   == Structure

   - `scans/` - panic-attack scan results per repo
   - `hardware/` - hardware-crash-team findings
   - `drift/` - drift detection snapshots
   - `index.json` - Master index of all stored data

   == Usage

   This repo receives scan results via GitHub Actions workflow_dispatch events
   and stores them as JSON files. The ingest workflow updates the index
   automatically.
   ```

5. Create `.github/workflows/ingest.yml`:
   ```yaml
   name: Ingest Scan Results

   on:
     repository_dispatch:
       types: [scan_result]
     workflow_dispatch:
       inputs:
         repo_name:
           description: 'Repository name'
           required: true
         scan_data:
           description: 'JSON scan data'
           required: true

   jobs:
     ingest:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4

         - name: Store scan result
           run: |
             REPO_NAME="${{ github.event.client_payload.repo_name || github.event.inputs.repo_name }}"
             SCAN_DATA='${{ github.event.client_payload.scan_data || github.event.inputs.scan_data }}'

             echo "$SCAN_DATA" > "scans/${REPO_NAME}.json"

             # Update index.json (simple jq append)
             jq --arg repo "$REPO_NAME" --arg time "$(date -Iseconds)" \
               '.repos[$repo] = {last_scan: $time, weak_points: ($SCAN_DATA | fromjson | .weak_points | length)} | .total_scans += 1 | .last_updated = $time' \
               index.json > index.tmp && mv index.tmp index.json

         - name: Commit changes
           run: |
             git config user.name "VeriSimDB Bot"
             git config user.email "bot@verisimdb.org"
             git add scans/ index.json
             git commit -m "scan: update ${REPO_NAME} results"
             git push
   ```

6. Commit and push to GitHub:
   ```bash
   git add .
   git commit -m "feat: initial verisimdb-data repo structure"
   git remote add origin git@github.com:hyperpolymath/verisimdb-data.git
   git push -u origin main
   ```

**Success criteria**: Repo exists at github.com/hyperpolymath/verisimdb-data with ingest workflow

---

## Task 2: Add Reusable Scan Workflow to panic-attack

**Estimated time**: 20 minutes

### Steps

1. In `panic-attacker` repo, create `.github/workflows/scan-and-report.yml`:
   ```yaml
   name: Scan and Report to VeriSimDB

   on:
     workflow_call:
       inputs:
         repo_path:
           description: 'Path to scan (default: .)'
           default: '.'
           type: string
     workflow_dispatch:

   jobs:
     scan:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4

         - name: Install Rust
           uses: dtolnay/rust-toolchain@stable

         - name: Install panic-attack
           run: |
             cargo install --git https://github.com/hyperpolymath/panic-attacker --branch main

         - name: Run scan
           id: scan
           run: |
             panic-attack assail ${{ inputs.repo_path }} --format json --output scan-result.json
             echo "scan_complete=true" >> $GITHUB_OUTPUT

         - name: Send to verisimdb-data
           if: steps.scan.outputs.scan_complete == 'true'
           run: |
             REPO_NAME=$(basename $(pwd))
             SCAN_DATA=$(cat scan-result.json)

             curl -X POST \
               -H "Authorization: Bearer ${{ secrets.GITHUB_TOKEN }}" \
               -H "Accept: application/vnd.github+json" \
               "https://api.github.com/repos/hyperpolymath/verisimdb-data/dispatches" \
               -d "{\"event_type\":\"scan_result\",\"client_payload\":{\"repo_name\":\"$REPO_NAME\",\"scan_data\":$SCAN_DATA}}"
   ```

2. Commit and push:
   ```bash
   git add .github/workflows/scan-and-report.yml
   git commit -m "feat: add reusable scan-and-report workflow for verisimdb integration"
   git push
   ```

**Success criteria**: Other repos can call `uses: hyperpolymath/panic-attacker/.github/workflows/scan-and-report.yml@main`

---

## Task 3: Test Pipeline with 3 Pilot Repos

**Estimated time**: 15 minutes

### Steps

Add the workflow to 3 repos as a test:

1. **echidna** - add `.github/workflows/security-scan.yml`:
   ```yaml
   name: Security Scan
   on:
     push:
       branches: [main]
     schedule:
       - cron: '0 0 * * 0'  # Weekly

   jobs:
     scan:
       uses: hyperpolymath/panic-attacker/.github/workflows/scan-and-report.yml@main
   ```

2. **ambientops** - same workflow

3. **verisimdb** - same workflow (dogfooding!)

4. Trigger manually to test:
   ```bash
   gh workflow run security-scan.yml --repo hyperpolymath/echidna
   ```

5. Verify results appear in verisimdb-data repo under `scans/`

**Success criteria**: All 3 repos scan successfully, results in verisimdb-data/scans/

---

## Task 4: Hypatia Integration - VeriSimDB Connector

**Estimated time**: 1 hour

### Steps

1. In `hypatia` repo, create `lib/verisimdb_connector.ex`:
   ```elixir
   defmodule Hypatia.VerisimdbConnector do
     @moduledoc """
     Reads scan results from verisimdb-data repo and transforms into Logtalk facts.
     """

     @verisimdb_data_path "~/Documents/hyperpolymath-repos/verisimdb-data"

     def fetch_all_scans do
       scans_path = Path.join(@verisimdb_data_path, "scans")

       File.ls!(scans_path)
       |> Enum.filter(&String.ends_with?(&1, ".json"))
       |> Enum.map(&load_scan/1)
     end

     defp load_scan(filename) do
       path = Path.join([@verisimdb_data_path, "scans", filename])
       repo_name = String.replace(filename, ".json", "")

       with {:ok, content} <- File.read(path),
            {:ok, data} <- Jason.decode(content) do
         %{repo: repo_name, scan: data}
       end
     end

     def to_logtalk_facts(scan_data) do
       # Transform weak points into Logtalk facts
       scan_data.scan["weak_points"]
       |> Enum.map(fn wp ->
         """
         weak_point('#{scan_data.repo}', '#{wp["file"]}', #{wp["category"]}, #{wp["severity"]}).
         """
       end)
       |> Enum.join("\n")
     end
   end
   ```

2. Create Logtalk rule file `prolog/pattern_detection.lgt`:
   ```logtalk
   % Pattern detection rules for scan results

   :- object(pattern_detector).

   % Detect widespread unsafe pattern
   :- public(widespread_unsafe/2).
   widespread_unsafe(Pattern, Repos) :-
       findall(Repo, weak_point(Repo, _, Pattern, high), Repos),
       length(Repos, Count),
       Count >= 3.

   % Detect deteriorating repo
   :- public(deteriorating/1).
   deteriorating(Repo) :-
       % TODO: Compare current vs previous scan
       % Needs temporal data
       fail.

   :- end_object.
   ```

3. Create integration module `lib/pattern_analyzer.ex`:
   ```elixir
   defmodule Hypatia.PatternAnalyzer do
     alias Hypatia.VerisimdbConnector

     def analyze_all_scans do
       scans = VerisimdbConnector.fetch_all_scans()

       # Write facts to temp file
       facts = Enum.map_join(scans, "\n", &VerisimdbConnector.to_logtalk_facts/1)
       File.write!("/tmp/scan_facts.lgt", facts)

       # Load into Logtalk and run queries
       # TODO: Integrate with actual Logtalk interpreter
       {:ok, scans}
     end
   end
   ```

4. Test:
   ```bash
   cd hypatia
   mix test test/verisimdb_connector_test.exs
   ```

**Success criteria**: Hypatia can read verisimdb-data and generate Logtalk facts

---

## Task 5: Fleet Dispatch Integration

**Estimated time**: 45 minutes

### Steps

1. In `hypatia` repo, create `lib/fleet_dispatcher.ex`:
   ```elixir
   defmodule Hypatia.FleetDispatcher do
     @moduledoc """
     Routes findings to appropriate gitbot-fleet bots via GraphQL.
     """

     def dispatch_finding(finding) do
       case finding.type do
         :eco_score -> dispatch_to_sustainabot(finding)
         :proof_obligation -> dispatch_to_echidnabot(finding)
         :fix_suggestion -> dispatch_to_rhodibot(finding)
         _ -> {:error, :unknown_finding_type}
       end
     end

     defp dispatch_to_sustainabot(finding) do
       # GraphQL mutation to sustainabot
       mutation = """
       mutation {
         reportEcoScore(
           repo: "#{finding.repo}",
           score: #{finding.score},
           details: "#{finding.details}"
         ) {
           success
         }
       }
       """

       execute_graphql(mutation, "sustainabot")
     end

     defp dispatch_to_echidnabot(finding) do
       # Similar GraphQL mutation
       {:ok, :dispatched}
     end

     defp dispatch_to_rhodibot(finding) do
       # Similar GraphQL mutation
       {:ok, :dispatched}
     end

     defp execute_graphql(query, bot_name) do
       # TODO: Actual GraphQL client call
       # For now, just log
       require Logger
       Logger.info("Would dispatch to #{bot_name}: #{query}")
       {:ok, :logged}
     end
   end
   ```

2. Wire it up in the pattern analyzer:
   ```elixir
   # In lib/pattern_analyzer.ex, add:

   def process_findings(findings) do
     Enum.each(findings, fn finding ->
       case FleetDispatcher.dispatch_finding(finding) do
         {:ok, _} -> :ok
         {:error, reason} -> Logger.error("Dispatch failed: #{reason}")
       end
     end)
   end
   ```

**Success criteria**: Pattern findings route to correct bot (logged for now, real GraphQL later)

---

## Verification Checklist

After completing all tasks:

- [ ] verisimdb-data repo exists and ingest workflow works
- [ ] panic-attack has reusable scan-and-report workflow
- [ ] 3 pilot repos (echidna, ambientops, verisimdb) scan successfully
- [ ] Scan results visible in verisimdb-data/scans/
- [ ] Hypatia can read scans and generate Logtalk facts
- [ ] Fleet dispatcher routes findings (logged, not yet live GraphQL)

---

## Notes

- All credentials already in `~/.netrc` (Cloudflare, Fly.io ready for future deployment)
- Fly.io deployment is DEFERRED - flat-file approach works for now
- GraphQL endpoints for gitbot-fleet are placeholders - bots need to expose these
- See `.claude/CLAUDE.md` in each repo for additional context

---

**After completion**, update verisimdb STATE.scm to reflect:
- GitHub CI integration: COMPLETE
- Hypatia pipeline: INITIAL (connector working, fleet dispatch logged)
