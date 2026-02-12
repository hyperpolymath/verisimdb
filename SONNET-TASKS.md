# SONNET-TASKS.md — VeriSimDB

**Date:** 2026-02-12
**Repo:** `/var/mnt/eclipse/repos/verisimdb/`
**Written by:** Opus (for Sonnet to execute)
**Estimated total time:** 4-5 hours
**Honest completion before these tasks:** ~65-70%
**Target completion after these tasks:** ~90%

---

## Ground Rules

### Languages
- **Rust** — all crates under `rust-core/`. Edition 2021. Workspace root is `/var/mnt/eclipse/repos/verisimdb/Cargo.toml`.
- **Elixir** — files under `elixir-orchestration/` and `lib/`. Mix project is `elixir-orchestration/mix.exs`.
- **ReScript** — files under `src/vql/`. Do NOT touch the parser (`VQLParser.res`); it works.

### What NOT to touch (these work — leave them alone)
- `src/vql/VQLParser.res` — functional VQL parser
- `src/vql/VQLError.res` — error types
- `src/vql/VQLTypeChecker.res` — type checker
- `rust-core/verisim-graph/` — Oxigraph integration works
- `rust-core/verisim-temporal/` — version trees work
- `rust-core/verisim-drift/` — drift detection logic works
- `rust-core/verisim-normalizer/` — self-normalization works
- `rust-core/verisim-hexad/` — core entity model works
- `rust-core/verisim-api/src/lib.rs` — HTTP API works (do NOT rewrite; only add `[[bin]]` if needed)
- `lib/verisim/adaptive_learner.ex` — fully implemented, 4 domains

### Testing requirements
- Every Rust change: `cargo test -p <crate-name>` must pass
- Every Elixir change: `mix test` in `elixir-orchestration/` must pass
- Run `cargo clippy --workspace` at end — zero warnings
- Run `cargo build --workspace` at end — must compile clean

### Author attribution
- Git commits: `Jonathan D.A. Jewell <jonathan.jewell@open.ac.uk>`
- Cargo.toml authors field: `["Jonathan D.A. Jewell <jonathan.jewell@open.ac.uk>"]`

---

## Task 1: Fix Tensor ReduceOp::Max, Min, Prod (WRONG RESULTS)

### Files
- `/var/mnt/eclipse/repos/verisimdb/rust-core/verisim-tensor/src/lib.rs`

### Problem
Lines 240-249: `ReduceOp::Max`, `ReduceOp::Min`, and `ReduceOp::Prod` all fall through to `arr.sum_axis(...)`. This means calling `reduce("t1", 0, ReduceOp::Max)` returns the SUM, not the MAX. The comments on lines 243, 245, and 248 say "TODO: proper max/min/prod".

Current broken code (lines 237-250):
```rust
let reduced = match op {
    ReduceOp::Sum => arr.sum_axis(ndarray::Axis(axis)),
    ReduceOp::Mean => arr.mean_axis(ndarray::Axis(axis)).expect("non-empty axis"),
    ReduceOp::Max => {
        // ndarray doesn't have max_axis that returns ArrayD directly
        // Simplified implementation for now
        arr.sum_axis(ndarray::Axis(axis)) // TODO: proper max
    }
    ReduceOp::Min => arr.sum_axis(ndarray::Axis(axis)), // TODO: proper min
    ReduceOp::Prod => {
        // No built-in prod_axis
        arr.sum_axis(ndarray::Axis(axis)) // TODO: proper prod
    }
};
```

### What to do

Replace the `ReduceOp::Max`, `ReduceOp::Min`, and `ReduceOp::Prod` arms with correct implementations. ndarray does not have built-in `max_axis`/`min_axis`/`prod_axis` that return `ArrayD` directly, so you need to use `map_axis`:

```rust
ReduceOp::Max => {
    arr.map_axis(ndarray::Axis(axis), |lane| {
        lane.iter().copied().fold(f64::NEG_INFINITY, f64::max)
    })
}
ReduceOp::Min => {
    arr.map_axis(ndarray::Axis(axis), |lane| {
        lane.iter().copied().fold(f64::INFINITY, f64::min)
    })
}
ReduceOp::Prod => {
    arr.map_axis(ndarray::Axis(axis), |lane| {
        lane.iter().copied().product()
    })
}
```

Then add tests at the bottom of the `mod tests` block (after line 277):

```rust
#[tokio::test]
async fn test_reduce_max() {
    let store = InMemoryTensorStore::new();
    // 2x3 tensor: [[1, 5, 3], [4, 2, 6]]
    let tensor = Tensor::new("t_max", vec![2, 3], vec![1.0, 5.0, 3.0, 4.0, 2.0, 6.0]).unwrap();
    store.put(&tensor).await.unwrap();

    // Max along axis 0 → [4, 5, 6]
    let result = store.reduce("t_max", 0, ReduceOp::Max).await.unwrap();
    assert_eq!(result.data, vec![4.0, 5.0, 6.0]);

    // Max along axis 1 → [5, 6]
    let result = store.reduce("t_max", 1, ReduceOp::Max).await.unwrap();
    assert_eq!(result.data, vec![5.0, 6.0]);
}

#[tokio::test]
async fn test_reduce_min() {
    let store = InMemoryTensorStore::new();
    let tensor = Tensor::new("t_min", vec![2, 3], vec![1.0, 5.0, 3.0, 4.0, 2.0, 6.0]).unwrap();
    store.put(&tensor).await.unwrap();

    // Min along axis 0 → [1, 2, 3]
    let result = store.reduce("t_min", 0, ReduceOp::Min).await.unwrap();
    assert_eq!(result.data, vec![1.0, 2.0, 3.0]);
}

#[tokio::test]
async fn test_reduce_prod() {
    let store = InMemoryTensorStore::new();
    let tensor = Tensor::new("t_prod", vec![2, 3], vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0]).unwrap();
    store.put(&tensor).await.unwrap();

    // Prod along axis 0 → [1*4, 2*5, 3*6] = [4, 10, 18]
    let result = store.reduce("t_prod", 0, ReduceOp::Prod).await.unwrap();
    assert_eq!(result.data, vec![4.0, 10.0, 18.0]);
}
```

### Verification
```bash
cd /var/mnt/eclipse/repos/verisimdb
cargo test -p verisim-tensor
# Must see: test_reduce_max ... ok
# Must see: test_reduce_min ... ok
# Must see: test_reduce_prod ... ok
```

---

## Task 2: Re-enable HNSW Vector Indexing

### Files
- `/var/mnt/eclipse/repos/verisimdb/rust-core/verisim-vector/Cargo.toml`
- `/var/mnt/eclipse/repos/verisimdb/rust-core/verisim-vector/src/lib.rs`

### Problem
Line 12 of `Cargo.toml`: `# hnsw_rs.workspace = true  # TODO: Re-enable when implementing proper HNSW with lifetime management`

The HNSW dependency is commented out. The `HnswVectorStore` struct (line 109 of `lib.rs`) is misleadingly named — it uses brute-force linear scan, not HNSW. This is O(n) per query instead of O(log n).

### What to do

**Option A (preferred):** Re-enable `hnsw_rs` and add a proper HNSW-backed implementation alongside the existing brute-force store.

1. In `Cargo.toml` line 12, uncomment:
   ```toml
   hnsw_rs.workspace = true
   ```

2. In `lib.rs`, rename the current struct from `HnswVectorStore` to `BruteForceVectorStore` (it is NOT HNSW). Keep it as a fallback.

3. Add a new `HnswVectorStore` that wraps `hnsw_rs::Hnsw`. The key challenge is lifetime management — `hnsw_rs::Hnsw` has a generic distance parameter. Use `hnsw_rs::dist::DistCosine` for cosine, `hnsw_rs::dist::DistL2` for euclidean.

4. If `hnsw_rs` causes compilation issues (lifetime problems are common), fall back to **Option B**.

**Option B (fallback):** If `hnsw_rs` integration is too complex, do the following instead:
1. Keep `hnsw_rs` commented out.
2. Rename `HnswVectorStore` to `BruteForceVectorStore`.
3. Add a comment explaining why HNSW is deferred.
4. Add a `// TODO: HNSW integration deferred — brute-force O(n) search used. Acceptable for <10k vectors.` comment.
5. Update the Cargo.toml comment to say `# Deferred: lifetime management issues with hnsw_rs 0.3`.

Either way, the misleading name `HnswVectorStore` MUST be fixed.

### Verification
```bash
cd /var/mnt/eclipse/repos/verisimdb
cargo test -p verisim-vector
cargo build -p verisim-vector
# If Option A: ensure HNSW tests pass
# If Option B: ensure brute-force tests still pass, struct renamed
grep -n "BruteForceVectorStore\|HnswVectorStore" rust-core/verisim-vector/src/lib.rs
```

---

## Task 3: Implement Document Search Highlighting

### Files
- `/var/mnt/eclipse/repos/verisimdb/rust-core/verisim-document/src/lib.rs`

### Problem
Line 251: `snippet: None, // TODO: implement highlighting`

When searching documents, the `SearchResult.snippet` field is always `None`. Users cannot see WHERE in the document their query matched.

### What to do

Use Tantivy's built-in `SnippetGenerator` to produce highlighted snippets. Modify the `search` method of `TantivyDocumentStore` (starts at line 221).

Replace the search result construction (lines 231-253) with code that generates snippets:

```rust
async fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchResult>, DocumentError> {
    let searcher = self.reader.searcher();
    let query_parser = QueryParser::for_index(
        &self.index,
        vec![self.schema.title, self.schema.body],
    );

    let parsed_query = query_parser.parse_query(query)?;
    let top_docs = searcher.search(&parsed_query, &TopDocs::with_limit(limit))?;

    // Create snippet generator for body field
    let snippet_generator = tantivy::SnippetGenerator::create(
        &searcher,
        &parsed_query,
        self.schema.body,
    )?;

    let mut results = Vec::new();
    for (score, doc_address) in top_docs {
        let retrieved_doc: TantivyDocument = searcher.doc(doc_address)?;

        let id = retrieved_doc
            .get_first(self.schema.id)
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        let title = retrieved_doc
            .get_first(self.schema.title)
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        // Generate snippet with highlights
        let snippet = snippet_generator.snippet_from_doc(&retrieved_doc);
        let snippet_html = snippet.to_html();
        let snippet_text = if snippet_html.is_empty() {
            None
        } else {
            Some(snippet_html)
        };

        results.push(SearchResult {
            id,
            score,
            title,
            snippet: snippet_text,
        });
    }

    Ok(results)
}
```

You will need to add `use tantivy::SnippetGenerator;` at the top of the file (or use the fully qualified path `tantivy::SnippetGenerator`).

**IMPORTANT:** Check the Tantivy 0.25 API. The `SnippetGenerator` API may differ between versions. If `SnippetGenerator::create` does not exist in 0.25, check for `SnippetGenerator::new` or similar. Look at Tantivy 0.25 docs.

Add a test that verifies snippets are returned:

```rust
#[tokio::test]
async fn test_search_with_snippets() {
    let store = TantivyDocumentStore::in_memory().unwrap();

    let doc = Document::new(
        "d1",
        "Rust Guide",
        "Rust is a systems programming language focused on safety and performance",
    );
    store.index(&doc).await.unwrap();
    store.commit().await.unwrap();

    let results = store.search("safety", 10).await.unwrap();
    assert_eq!(results.len(), 1);
    assert!(results[0].snippet.is_some(), "Snippet should not be None");
    let snippet = results[0].snippet.as_ref().unwrap();
    assert!(snippet.contains("safety"), "Snippet should contain the search term");
}
```

### Verification
```bash
cd /var/mnt/eclipse/repos/verisimdb
cargo test -p verisim-document
# Must see: test_search_with_snippets ... ok
# Snippet field should contain highlighted text
```

---

## Task 4: Fix verisim-api Binary Target

### Files
- `/var/mnt/eclipse/repos/verisimdb/rust-core/verisim-api/Cargo.toml`
- `/var/mnt/eclipse/repos/verisimdb/rust-core/verisim-api/src/main.rs` (already exists)

### Problem
`cargo run -p verisim-api` may fail because `Cargo.toml` has no explicit `[[bin]]` section. A `src/main.rs` file exists at `/var/mnt/eclipse/repos/verisimdb/rust-core/verisim-api/src/main.rs` which imports `verisim_api::ApiConfig` and calls `verisim_api::serve(config)` — both of which exist in `lib.rs`. Cargo should auto-detect this, but verify it works.

### What to do

1. Run `cargo run -p verisim-api` to verify it compiles and starts. If it works, skip step 2.

2. If it fails, add this to the bottom of `rust-core/verisim-api/Cargo.toml`:

```toml
[[bin]]
name = "verisim-api"
path = "src/main.rs"
```

3. Also fix the `authors` field in the workspace Cargo.toml at `/var/mnt/eclipse/repos/verisimdb/Cargo.toml` line 23:

Change:
```toml
authors = ["hyperpolymath"]
```
To:
```toml
authors = ["Jonathan D.A. Jewell <jonathan.jewell@open.ac.uk>"]
```

### Verification
```bash
cd /var/mnt/eclipse/repos/verisimdb
cargo build -p verisim-api
# Must compile with no errors
# The binary should appear at target/debug/verisim-api
ls target/debug/verisim-api
```

---

## Task 5: Implement L2 and L3 Cache

### Files
- `/var/mnt/eclipse/repos/verisimdb/lib/verisim/query_cache.ex`

### Problem
Lines 429-456: Six functions are stubs:
- `get_from_l2/1` (line 429) returns `{:error, :not_implemented}`
- `put_in_l2/2` (line 434) returns `:ok` (no-op)
- `get_from_l3/1` (line 439) returns `{:error, :not_implemented}`
- `put_in_l3/2` (line 444) returns `:ok` (no-op)
- `clear_l2/0` (line 449) returns `:ok` (no-op)
- `clear_l3/0` (line 454) returns `:ok` (no-op)

Also line 463: `invalidate_key/1` has `# TODO: Invalidate L2 and L3`

L1 (ETS) works. L2 and L3 do nothing.

### What to do

**L2 (distributed cache):** Implement using a second ETS table named `:cache_l2` with a different eviction policy (larger TTL, lower access frequency). This is simpler than a full distributed cache and works for single-node deployment. A real distributed cache (Redis, distributed ETS) can replace it later.

1. In `init/1` (line 292-310), add after the `:cache_l1` creation:
   ```elixir
   :ets.new(:cache_l2, [:set, :public, :named_table, read_concurrency: true])
   ```

2. Replace `get_from_l2/1` (line 429-432):
   ```elixir
   defp get_from_l2(key) do
     case :ets.lookup(:cache_l2, key) do
       [{^key, entry}] ->
         if DateTime.compare(entry.expires_at, DateTime.utc_now()) == :gt do
           updated_entry = %{entry |
             access_count: entry.access_count + 1,
             last_accessed: DateTime.utc_now()
           }
           :ets.insert(:cache_l2, {key, updated_entry})
           {:ok, updated_entry}
         else
           :ets.delete(:cache_l2, key)
           {:error, :expired}
         end
       [] ->
         {:error, :not_found}
     end
   end
   ```

3. Replace `put_in_l2/2` (line 434-437):
   ```elixir
   defp put_in_l2(key, entry) do
     # L2 entries get 3x the TTL of L1
     extended_entry = %{entry |
       layer: :l2,
       expires_at: DateTime.add(entry.expires_at, entry.expires_at |> DateTime.diff(entry.created_at, :second) |> Kernel.*(2), :second)
     }
     :ets.insert(:cache_l2, {key, extended_entry})
     :ok
   end
   ```

4. Replace `clear_l2/0` (line 449-452):
   ```elixir
   defp clear_l2 do
     :ets.delete_all_objects(:cache_l2)
     :ok
   end
   ```

**L3 (persistent cache):** Implement using file-based storage in a temp directory. Write cache entries as JSON files. This is a simple persistent cache that survives process restarts.

5. Replace `get_from_l3/1` (line 439-442):
   ```elixir
   defp get_from_l3(key) do
     path = l3_cache_path(key)
     case File.read(path) do
       {:ok, content} ->
         case :erlang.binary_to_term(content) do
           %CacheEntry{} = entry ->
             if DateTime.compare(entry.expires_at, DateTime.utc_now()) == :gt do
               {:ok, entry}
             else
               File.rm(path)
               {:error, :expired}
             end
           _ ->
             {:error, :not_found}
         end
       {:error, _} ->
         {:error, :not_found}
     end
   end
   ```

6. Replace `put_in_l3/2` (line 444-447):
   ```elixir
   defp put_in_l3(key, entry) do
     path = l3_cache_path(key)
     File.mkdir_p!(Path.dirname(path))
     l3_entry = %{entry | layer: :l3}
     File.write!(path, :erlang.term_to_binary(l3_entry))
     :ok
   end
   ```

7. Replace `clear_l3/0` (line 454-457):
   ```elixir
   defp clear_l3 do
     l3_dir = l3_cache_dir()
     if File.exists?(l3_dir) do
       File.rm_rf!(l3_dir)
       File.mkdir_p!(l3_dir)
     end
     :ok
   end
   ```

8. Add helper functions before the `get_config` function:
   ```elixir
   defp l3_cache_dir do
     Path.join(System.tmp_dir!(), "verisimdb_cache_l3")
   end

   defp l3_cache_path(key) do
     safe_key = key |> :erlang.phash2() |> Integer.to_string()
     Path.join(l3_cache_dir(), "#{safe_key}.cache")
   end
   ```

9. Update `invalidate_key/1` (line 459-465) to also invalidate L2 and L3:
   ```elixir
   defp invalidate_key(key) do
     :ets.delete(:cache_l1, key)
     :ets.delete(:cache_l2, key)
     :ets.match_delete(:cache_tags, {key, :_})

     # Invalidate L3
     path = l3_cache_path(key)
     File.rm(path)

     :ok
   end
   ```

### Verification
```bash
cd /var/mnt/eclipse/repos/verisimdb/elixir-orchestration
mix compile
# No warnings about undefined functions

# Verify the stubs are gone:
grep -n "not_implemented" ../lib/verisim/query_cache.ex
# Should return NO results
```

---

## Task 6: Integrate VQL Parser in QueryRouter

### Files
- `/var/mnt/eclipse/repos/verisimdb/lib/verisim/query_router_cached.ex`

### Problem
Line 270-273: `parse_query/1` returns a HARDCODED mock AST instead of calling the actual ReScript VQL parser:
```elixir
defp parse_query(raw_query) do
    # Call VQL parser
    # TODO: Implement actual parser call
    %{raw: raw_query, modalities: ["GRAPH"], source: {:hexad, "abc-123"}}
end
```

Line 300-303: `modality_to_string/1` is a no-op:
```elixir
defp modality_to_string(modality) do
    # TODO: Implement proper conversion
    "#{modality}"
end
```

### What to do

1. Replace `parse_query/1` (lines 270-273) with a function that calls the VQL executor. The VQL executor already exists at `elixir-orchestration/lib/verisim/query/vql_executor.ex`. Check what interface it exposes (likely `VeriSim.VQLExecutor.parse/1` or similar).

   If `VeriSim.VQLExecutor` has a parse function, use it:
   ```elixir
   defp parse_query(raw_query) do
     case VeriSim.VQLExecutor.parse(raw_query) do
       {:ok, ast} -> ast
       {:error, reason} ->
         Logger.error("VQL parse failed: #{inspect(reason)}")
         # Fallback to basic extraction
         %{raw: raw_query, modalities: extract_modalities(raw_query), source: extract_source(raw_query)}
     end
   end
   ```

   If `VeriSim.VQLExecutor` does NOT have a parse function, implement a simple regex-based modality extractor as interim:
   ```elixir
   defp parse_query(raw_query) do
     modalities = extract_modalities(raw_query)
     source = extract_source(raw_query)
     %{raw: raw_query, modalities: modalities, source: source}
   end

   defp extract_modalities(query) do
     upper = String.upcase(query)
     modalities = []
     modalities = if String.contains?(upper, "GRAPH"), do: ["GRAPH" | modalities], else: modalities
     modalities = if String.contains?(upper, "VECTOR"), do: ["VECTOR" | modalities], else: modalities
     modalities = if String.contains?(upper, "TENSOR"), do: ["TENSOR" | modalities], else: modalities
     modalities = if String.contains?(upper, "SEMANTIC"), do: ["SEMANTIC" | modalities], else: modalities
     modalities = if String.contains?(upper, "DOCUMENT"), do: ["DOCUMENT" | modalities], else: modalities
     modalities = if String.contains?(upper, "TEMPORAL"), do: ["TEMPORAL" | modalities], else: modalities
     if modalities == [], do: ["GRAPH"], else: Enum.reverse(modalities)
   end

   defp extract_source(query) do
     cond do
       String.contains?(query, "FEDERATION") ->
         case Regex.run(~r/FEDERATION\s+(\S+)/, query) do
           [_, pattern] -> {:federation, pattern, %{}}
           _ -> {:hexad, "unknown"}
         end
       true ->
         {:hexad, "unknown"}
     end
   end
   ```

2. Replace `modality_to_string/1` (lines 300-303):
   ```elixir
   defp modality_to_string(modality) when is_binary(modality), do: modality
   defp modality_to_string(modality) when is_atom(modality) do
     modality |> Atom.to_string() |> String.upcase()
   end
   defp modality_to_string(modality), do: "#{modality}"
   ```

### Verification
```bash
cd /var/mnt/eclipse/repos/verisimdb/elixir-orchestration
mix compile
# No warnings

# Verify mock is gone:
grep -n "abc-123" ../lib/verisim/query_router_cached.ex
# Should return NO results

grep -n "TODO.*Implement actual parser" ../lib/verisim/query_router_cached.ex
# Should return NO results
```

---

## Task 7: Implement Query Condition Decomposition

### Files
- `/var/mnt/eclipse/repos/verisimdb/lib/verisim/query_planner_bidirectional.ex`

### Problem
Line 263-269: `decompose_conditions_by_modality/1` returns an empty map `%{}`. This means no WHERE conditions are ever pushed down to stores.

Line 276-279: `extract_fulltext_fields/1` returns an empty list `[]`. This means document query optimization never kicks in.

### What to do

1. Replace `decompose_conditions_by_modality/1` (lines 263-269):
   ```elixir
   defp decompose_conditions_by_modality(conditions) when is_list(conditions) do
     Enum.reduce(conditions, %{}, fn condition, acc ->
       modality = classify_condition_modality(condition)
       Map.update(acc, modality, [condition], &[condition | &1])
     end)
   end

   defp decompose_conditions_by_modality(conditions) when is_map(conditions) do
     # Single condition wrapped in a map
     modality = classify_condition_modality(conditions)
     %{modality => [conditions]}
   end

   defp decompose_conditions_by_modality(_), do: %{}

   defp classify_condition_modality(condition) when is_map(condition) do
     cond do
       Map.has_key?(condition, :embedding) or Map.has_key?(condition, :similar_to) ->
         "VECTOR"
       Map.has_key?(condition, :edge_type) or Map.has_key?(condition, :traversal) ->
         "GRAPH"
       Map.has_key?(condition, :fulltext) or Map.has_key?(condition, :contains) ->
         "DOCUMENT"
       Map.has_key?(condition, :proof) or Map.has_key?(condition, :contract) ->
         "SEMANTIC"
       Map.has_key?(condition, :shape) or Map.has_key?(condition, :tensor_op) ->
         "TENSOR"
       Map.has_key?(condition, :version) or Map.has_key?(condition, :as_of) ->
         "TEMPORAL"
       true ->
         "GRAPH"  # Default modality
     end
   end

   defp classify_condition_modality(condition) when is_binary(condition) do
     upper = String.upcase(condition)
     cond do
       String.contains?(upper, "SIMILAR") or String.contains?(upper, "EMBEDDING") -> "VECTOR"
       String.contains?(upper, "CITES") or String.contains?(upper, "EDGE") or String.contains?(upper, ")-[") -> "GRAPH"
       String.contains?(upper, "FULLTEXT") or String.contains?(upper, "CONTAINS") -> "DOCUMENT"
       String.contains?(upper, "PROOF") or String.contains?(upper, "VERIFY") -> "SEMANTIC"
       String.contains?(upper, "TENSOR") or String.contains?(upper, "SHAPE") -> "TENSOR"
       String.contains?(upper, "VERSION") or String.contains?(upper, "AS OF") -> "TEMPORAL"
       true -> "GRAPH"
     end
   end

   defp classify_condition_modality(_), do: "GRAPH"
   ```

2. Replace `extract_fulltext_fields/1` (lines 276-279):
   ```elixir
   defp extract_fulltext_fields(condition) when is_map(condition) do
     case Map.get(condition, :fulltext) do
       nil ->
         case Map.get(condition, :fields) do
           nil -> ["title", "body"]  # Default searchable fields
           fields when is_list(fields) -> fields
           field when is_binary(field) -> [field]
           _ -> ["title", "body"]
         end
       %{fields: fields} when is_list(fields) -> fields
       _ -> ["title", "body"]
     end
   end

   defp extract_fulltext_fields(_condition), do: ["title", "body"]
   ```

### Verification
```bash
cd /var/mnt/eclipse/repos/verisimdb/elixir-orchestration
mix compile

# Verify stubs are gone:
grep -n "TODO.*Implement condition decomposition" ../lib/verisim/query_planner_bidirectional.ex
# Should return NO results

grep -n "TODO.*Implement field extraction" ../lib/verisim/query_planner_bidirectional.ex
# Should return NO results
```

---

## Task 8: Implement Config Persistence

### Files
- `/var/mnt/eclipse/repos/verisimdb/lib/verisim/query_planner_config.ex`

### Problem
Line 246-249: `load_config_from_storage/0` returns `nil` (config never loaded from disk).
Line 252-256: `persist_config/1` is a no-op (config never saved).

### What to do

Implement file-based persistence. Store config as an Erlang term file.

1. Replace `load_config_from_storage/0` (lines 246-249):
   ```elixir
   defp load_config_from_storage do
     path = config_storage_path()
     case File.read(path) do
       {:ok, content} ->
         try do
           :erlang.binary_to_term(content)
         rescue
           _ -> nil
         end
       {:error, _} -> nil
     end
   end
   ```

2. Replace `persist_config/1` (lines 252-256):
   ```elixir
   defp persist_config(config) do
     path = config_storage_path()
     File.mkdir_p!(Path.dirname(path))
     File.write!(path, :erlang.term_to_binary(config))
     :ok
   rescue
     e ->
       require Logger
       Logger.warning("Failed to persist config: #{inspect(e)}")
       :ok
   end
   ```

3. Add the helper function:
   ```elixir
   defp config_storage_path do
     Path.join([System.tmp_dir!(), "verisimdb", "query_planner_config.bin"])
   end
   ```

### Verification
```bash
cd /var/mnt/eclipse/repos/verisimdb/elixir-orchestration
mix compile

grep -n "TODO.*Implement persistence" ../lib/verisim/query_planner_config.ex
# Should return NO results
```

---

## Task 9: Implement Drift Monitor Sweep

### Files
- `/var/mnt/eclipse/repos/verisimdb/elixir-orchestration/lib/verisim/drift/drift_monitor.ex`

### Problem
Lines 209-216: `perform_sweep/1` only updates the timestamp. It does NOT actually check for drift across entities:
```elixir
defp perform_sweep(state) do
    Logger.debug("Performing drift sweep")

    # In a real implementation, this would query the Rust core
    # for drift metrics across all entities

    %{state | last_sweep: DateTime.utc_now()}
end
```

### What to do

Replace `perform_sweep/1` (lines 209-216) with an implementation that iterates over known entities and checks drift scores:

```elixir
defp perform_sweep(state) do
  Logger.debug("Performing drift sweep across #{map_size(state.entity_drift)} entities")

  # Check each entity that has reported drift
  new_state = state.entity_drift
    |> Enum.reduce(state, fn {entity_id, drift_scores}, acc ->
      # Check each drift type for this entity
      Enum.reduce(drift_scores, acc, fn {drift_type, score}, inner_acc ->
        # Re-evaluate thresholds (scores may have changed since last check)
        maybe_trigger_normalization(inner_acc, entity_id, score, drift_type)
      end)
    end)

  # Also query RustClient for any new drift metrics
  new_state = case RustClient.get_drift_summary() do
    {:ok, drift_summary} ->
      Enum.reduce(drift_summary, new_state, fn {entity_id, metrics}, acc ->
        Enum.reduce(metrics, acc, fn {drift_type, score}, inner_acc ->
          # Update entity drift map
          new_entity_drift =
            Map.update(
              inner_acc.entity_drift,
              entity_id,
              %{drift_type => score},
              &Map.put(&1, drift_type, score)
            )
          inner_acc = %{inner_acc | entity_drift: new_entity_drift}
          maybe_trigger_normalization(inner_acc, entity_id, score, drift_type)
        end)
      end)

    {:error, reason} ->
      Logger.warning("Failed to query Rust core for drift: #{inspect(reason)}")
      new_state
  end

  %{new_state | last_sweep: DateTime.utc_now()}
end
```

**IMPORTANT:** The `RustClient.get_drift_summary/0` function may not exist yet. Check `elixir-orchestration/lib/verisim/rust_client.ex` for what functions exist. If `get_drift_summary/0` does not exist:

1. Add it to `rust_client.ex`:
   ```elixir
   def get_drift_summary do
     case get("/api/drift/summary") do
       {:ok, %{status_code: 200, body: body}} ->
         {:ok, Jason.decode!(body)}
       {:ok, %{status_code: status}} ->
         {:error, {:http_error, status}}
       {:error, reason} ->
         {:error, reason}
     end
   end
   ```

2. If `RustClient` does not have HTTP methods, make `perform_sweep` work with just the in-memory `entity_drift` map (skip the RustClient call, add a `# TODO: Query Rust core when HTTP client is ready` comment).

### Verification
```bash
cd /var/mnt/eclipse/repos/verisimdb/elixir-orchestration
mix compile

# Verify the stub is gone:
grep -n "In a real implementation" lib/verisim/drift/drift_monitor.ex
# Should return NO results
```

---

## Task 10: Fix ALL AGPL License Headers to PMPL-1.0-or-later

### Files (21 files total)

**Rust workspace (line 24):**
- `/var/mnt/eclipse/repos/verisimdb/Cargo.toml` — line 24: `license = "AGPL-3.0-or-later"` change to `license = "PMPL-1.0-or-later"`

**Elixir files (8 files, all line 1):**
- `/var/mnt/eclipse/repos/verisimdb/elixir-orchestration/mix.exs`
- `/var/mnt/eclipse/repos/verisimdb/elixir-orchestration/.formatter.exs`
- `/var/mnt/eclipse/repos/verisimdb/elixir-orchestration/config/config.exs`
- `/var/mnt/eclipse/repos/verisimdb/elixir-orchestration/config/dev.exs`
- `/var/mnt/eclipse/repos/verisimdb/elixir-orchestration/config/prod.exs`
- `/var/mnt/eclipse/repos/verisimdb/elixir-orchestration/config/runtime.exs`
- `/var/mnt/eclipse/repos/verisimdb/elixir-orchestration/config/test.exs`
- `/var/mnt/eclipse/repos/verisimdb/elixir-orchestration/test/test_helper.exs`
- `/var/mnt/eclipse/repos/verisimdb/elixir-orchestration/test/verisim_test.exs`

**Git/Container/FFI files:**
- `/var/mnt/eclipse/repos/verisimdb/.gitattributes` — line 1
- `/var/mnt/eclipse/repos/verisimdb/container/Containerfile` — line 1
- `/var/mnt/eclipse/repos/verisimdb/ffi/zig/build.zig` — line 2
- `/var/mnt/eclipse/repos/verisimdb/ffi/zig/src/main.zig` — line 6
- `/var/mnt/eclipse/repos/verisimdb/ffi/zig/test/integration_test.zig` — line 2

**Debugger/Practice-mirror:**
- `/var/mnt/eclipse/repos/verisimdb/debugger/examples/SafeDOMExample.res` — line 1
- `/var/mnt/eclipse/repos/verisimdb/practice-mirror/examples/SafeDOMExample.res` — line 1
- `/var/mnt/eclipse/repos/verisimdb/practice-mirror/verisimdb.ctp` — line 14: `license = "AGPL-3.0-or-later"` change to `license = "PMPL-1.0-or-later"`

**Documentation (content references, not headers):**
- `/var/mnt/eclipse/repos/verisimdb/docs/CITATIONS.adoc` — line 13: `license = {AGPL-3.0-or-later}` change to `license = {PMPL-1.0-or-later}`
- `/var/mnt/eclipse/repos/verisimdb/debugger/docs/CITATIONS.adoc` — line 13: same
- `/var/mnt/eclipse/repos/verisimdb/practice-mirror/docs/CITATIONS.adoc` — line 13: same

**RSR_OUTLINE.adoc (2 content references):**
- `/var/mnt/eclipse/repos/verisimdb/RSR_OUTLINE.adoc` — line 72: change `AGPL + Palimpsest dual license` to `PMPL-1.0-or-later (Palimpsest License)`
- `/var/mnt/eclipse/repos/verisimdb/RSR_OUTLINE.adoc` — line 160: change `LICENSE.txt` (AGPL + Palimpsest)` to `LICENSE.txt` (PMPL-1.0-or-later)`

### Problem
The codebase claims to have fixed AGPL headers to PMPL (STATE.scm session history says "Fixed 21 AGPL license headers to PMPL (2026-02-04)") but the headers are STILL AGPL. This is a license compliance issue.

### What to do

For EVERY file listed above, find the exact string `AGPL-3.0-or-later` and replace it with `PMPL-1.0-or-later`.

For SPDX header lines, the change is:
```
# SPDX-License-Identifier: AGPL-3.0-or-later
```
becomes:
```
# SPDX-License-Identifier: PMPL-1.0-or-later
```

For Zig files (use `//` comments):
```
// SPDX-License-Identifier: AGPL-3.0-or-later
```
becomes:
```
// SPDX-License-Identifier: PMPL-1.0-or-later
```

For ReScript files (use `//` comments):
```
// SPDX-License-Identifier: AGPL-3.0-or-later
```
becomes:
```
// SPDX-License-Identifier: PMPL-1.0-or-later
```

For `.gitattributes` (use `#` comments).
For `Containerfile` (use `#` comments).

**Do NOT change these files** (they already have PMPL-1.0-or-later):
- Any file under `rust-core/` (already fixed)
- `src/vql/*.res` (already fixed)
- `.machine_readable/*.scm` (already fixed)
- `lib/verisim/*.ex` (already fixed)

### Verification
```bash
cd /var/mnt/eclipse/repos/verisimdb
grep -r "AGPL" --include="*.toml" --include="*.exs" --include="*.ex" --include="*.zig" --include="*.res" --include="Containerfile" --include=".gitattributes" --include="*.adoc" --include="*.ctp" .
# Must return ZERO results (no AGPL references remaining)

# Double-check the workspace Cargo.toml:
grep 'license' Cargo.toml
# Must show: license = "PMPL-1.0-or-later"
```

---

## Task 11: Fix VQLExplain Mock Plan

### Files
- `/var/mnt/eclipse/repos/verisimdb/src/vql/VQLExplain.res`

### Problem
Line 172: `let plan = generateMockPlan(ast)  // TODO: Call actual planner`

The `explainQuery` function calls `generateMockPlan` (line 184) which returns hardcoded values (`estimatedCost: 100`, `estimatedSelectivity: 0.05` for every node). Real query plans should come from the Elixir QueryPlannerBidirectional.

### What to do

Since the ReScript code runs client-side (compiles to JS) and the Elixir planner runs server-side, the explain function cannot directly call Elixir. Instead:

1. Add a `generatePlanFromAst` function that analyzes the AST to produce more realistic estimates (not hardcoded `100` and `0.05`):

```rescript
// Generate plan based on actual AST analysis (replaces hardcoded mock)
let generatePlanFromAst = (ast: VQLParser.query): executionPlan => {
  let nodes = ast.modalities->Belt.Array.mapWithIndex((idx, modality) => {
    let modalityStr = switch modality {
    | Graph => "GRAPH"
    | Vector => "VECTOR"
    | Tensor => "TENSOR"
    | Semantic => "SEMANTIC"
    | Document => "DOCUMENT"
    | Temporal => "TEMPORAL"
    | All => "ALL"
    }

    // Estimate costs based on modality type
    let (cost, selectivity, hint) = switch modality {
    | Graph => (150, 0.2, Some("Graph traversal — O(E) scan"))
    | Vector => (50, 0.01, Some("HNSW approximate nearest neighbor"))
    | Tensor => (200, 0.5, Some("Tensor reduction — shape dependent"))
    | Semantic => (300, 0.8, Some("ZKP verification — expensive"))
    | Document => (80, 0.05, Some("Tantivy inverted index lookup"))
    | Temporal => (30, 0.1, Some("Version tree lookup — cached"))
    | All => (500, 1.0, Some("Full hexad scan across all modalities"))
    }

    // Adjust for LIMIT clause
    let adjustedSelectivity = switch ast.limit {
    | Some(limit) =>
      let limitF = Belt.Float.fromInt(limit)
      Js.Math.min_float(selectivity, limitF /. 1000.0)
    | None => selectivity
    }

    {
      step: idx + 1,
      operation: "Query",
      modality: modalityStr,
      estimatedCost: cost,
      estimatedSelectivity: adjustedSelectivity,
      optimizationHint: hint,
      pushedPredicates: [],
    }
  })

  // Determine strategy
  let strategy = if Js.Array2.length(nodes) > 1 {
    #Parallel
  } else {
    #Sequential
  }

  let totalCost = nodes->Belt.Array.reduce(0, (acc, node) => acc + node.estimatedCost)

  {
    strategy: strategy,
    totalCost: totalCost,
    optimizationMode: "Balanced (client-side estimate)",
    nodes: nodes,
    bidirectionalOptimization: false,
  }
}
```

2. In the `explainQuery` function (line 165-181), change line 172 from:
   ```rescript
   let plan = generateMockPlan(ast)  // TODO: Call actual planner
   ```
   to:
   ```rescript
   let plan = generatePlanFromAst(ast)
   ```

3. Keep `generateMockPlan` for test purposes but add a comment:
   ```rescript
   // Deprecated: Use generatePlanFromAst instead. Kept for test compatibility only.
   let generateMockPlan = (ast: VQLParser.query): executionPlan => {
   ```

### Verification
```bash
cd /var/mnt/eclipse/repos/verisimdb
grep -n "generateMockPlan" src/vql/VQLExplain.res
# Should only appear in the deprecated function definition and testExplain, NOT in explainQuery

grep -n "TODO.*Call actual planner" src/vql/VQLExplain.res
# Should return NO results
```

---

## Task 12: Update STATE.scm to Honest Values

### Files
- `/var/mnt/eclipse/repos/verisimdb/.machine_readable/STATE.scm`

### Problem
Lines 44-46 claim:
```scheme
(phase . "production-ready")
(overall-completion . 100)
```

This is FALSE. The project is NOT production-ready. Multiple core features are stubs (L2/L3 cache, drift sweep, query routing, condition decomposition, HNSW, etc.).

Line 47-57 claims `elixir-orchestration . 100` and `vql-implementation . 100` — both false.

Line 86 claims: `"- None! Project is production-ready for v0.1.0-alpha release"` — false.

### What to do

Update `current-position` (starting at line 43) with honest values. After completing Tasks 1-11, the realistic values are:

```scheme
(define current-position
  '((phase . "alpha-development")
    (overall-completion . 75)
    (components
      ((architecture-design . 100)
       (vql-implementation . 85)
       (documentation . 100)
       (rust-modality-stores . 85)
       (elixir-orchestration . 70)
       (rescript-registry . 60)
       (integration-tests . 70)
       (performance-benchmarks . 50)
       (deployment-guide . 80)
       (github-ci-integration . 100)
       (hypatia-pipeline . 40)))
```

Update `blocked-on` (line 86) to:
```scheme
(blocked-on
  "- HNSW vector indexing: hnsw_rs lifetime management
   - Federation protocol: Not yet implemented
   - ZKP integration: proven library not yet integrated
   - Real VQL parser integration in query router (Port/HTTP bridge needed)")
```

Update the `updated` field (line 8) to today's date: `"2026-02-12"`.

Add a new session to `session-history` (after line 264):
```scheme
(session
  (date . "2026-02-12")
  (phase . "honest-audit-and-stub-fixes")
  (accomplishments
    "- Fixed tensor ReduceOp::Max/Min/Prod returning wrong results (was sum)
     - Fixed HNSW vector store naming (brute-force, not HNSW)
     - Implemented document search highlighting (Tantivy snippets)
     - Implemented L2/L3 cache layers (were stubs)
     - Implemented query condition decomposition (was empty map)
     - Implemented config persistence (was no-op)
     - Implemented drift monitor sweep (was timestamp-only)
     - Fixed 21 AGPL license headers to PMPL-1.0-or-later
     - Replaced VQLExplain mock plan with AST-based estimates
     - Updated STATE.scm with honest completion percentages")
  (key-decisions
    "- Honest audit: overall completion ~75%, not 100%
     - L2 cache: ETS-based (single-node), not distributed
     - L3 cache: File-based, survives restarts
     - Config persistence: Erlang term file in /tmp"))
```

### Verification
```bash
grep "overall-completion" /var/mnt/eclipse/repos/verisimdb/.machine_readable/STATE.scm
# Must NOT show 100

grep "production-ready" /var/mnt/eclipse/repos/verisimdb/.machine_readable/STATE.scm
# Must NOT appear (should be "alpha-development")
```

---

## Task 13: Replace bincode Pre-release Dependency

### Files
- `/var/mnt/eclipse/repos/verisimdb/Cargo.toml` (workspace root)
- Any crate that uses `bincode` (check with `grep -r "bincode" rust-core/`)

### Problem
Line 57: `bincode = "2.0.0-rc.3"  # TODO: Migrate to maintained alternative (ciborium, postcard)`

Using a release candidate in production code is risky. The comment itself says to migrate.

### What to do

1. Check which crates actually use `bincode`:
   ```bash
   grep -rn "use bincode\|bincode::" rust-core/
   ```

2. If `bincode` is only used for serialization/deserialization, replace with `postcard` (already in the workspace at line 58: `postcard = { version = "1.0", features = ["alloc"] }`).

3. In the workspace `Cargo.toml`, remove or comment out the bincode line:
   ```toml
   # bincode removed — use postcard or ciborium instead
   # bincode = "2.0.0-rc.3"
   ```

4. In each crate `Cargo.toml` that had `bincode.workspace = true`, change to `postcard.workspace = true`.

5. In the Rust source files, replace `bincode::serialize`/`bincode::deserialize` with `postcard::to_allocvec`/`postcard::from_bytes`.

   Example migration:
   ```rust
   // Before:
   let bytes = bincode::serialize(&data)?;
   let data: MyType = bincode::deserialize(&bytes)?;

   // After:
   let bytes = postcard::to_allocvec(&data)?;
   let data: MyType = postcard::from_bytes(&bytes)?;
   ```

6. If `bincode` is used in too many places to migrate quickly, at minimum update the comment to document the risk and pin the exact version.

### Verification
```bash
cd /var/mnt/eclipse/repos/verisimdb
cargo build --workspace
# Must compile cleanly

grep -n "bincode" Cargo.toml
# Should show commented-out line only (or no results)

grep -rn "use bincode" rust-core/
# Should return NO results (or show postcard replacements)
```

---

## Final Verification

After completing ALL 13 tasks, run these commands in order:

```bash
cd /var/mnt/eclipse/repos/verisimdb

# 1. Rust workspace compiles
cargo build --workspace

# 2. All Rust tests pass
cargo test --workspace

# 3. No Clippy warnings
cargo clippy --workspace -- -D warnings

# 4. Elixir compiles
cd elixir-orchestration && mix deps.get && mix compile && cd ..

# 5. No AGPL references remain
grep -r "AGPL" --include="*.toml" --include="*.exs" --include="*.ex" --include="*.zig" --include="*.res" --include="Containerfile" --include=".gitattributes" --include="*.adoc" --include="*.ctp" .
# Must return ZERO results

# 6. No "not_implemented" stubs remain in cache
grep -n "not_implemented" lib/verisim/query_cache.ex
# Must return ZERO results

# 7. No mock AST in query router
grep -n "abc-123" lib/verisim/query_router_cached.ex
# Must return ZERO results

# 8. STATE.scm is honest
grep "overall-completion" .machine_readable/STATE.scm
# Must NOT show 100

# 9. Tensor reduce operations are correct (not sum fallbacks)
grep -n "TODO: proper" rust-core/verisim-tensor/src/lib.rs
# Must return ZERO results

# 10. Author field is correct
grep "authors" Cargo.toml | head -1
# Must show: authors = ["Jonathan D.A. Jewell <jonathan.jewell@open.ac.uk>"]

# 11. Binary target works
cargo build -p verisim-api
ls target/debug/verisim-api
# Must exist
```

If ALL 11 checks pass, commit everything:

```bash
git add -A
git commit -m "fix: resolve 13 audit findings — honest completion, fix stubs, correct license headers

- Fix tensor ReduceOp::Max/Min/Prod (were returning sum)
- Fix HNSW naming (was brute-force, misleadingly named)
- Implement document search highlighting (Tantivy snippets)
- Implement L2/L3 cache layers (were no-op stubs)
- Integrate VQL parser in QueryRouter (was hardcoded mock)
- Implement query condition decomposition (was empty map)
- Implement config persistence (was no-op)
- Implement drift monitor sweep (was timestamp-only)
- Fix 21 AGPL license headers to PMPL-1.0-or-later
- Replace VQLExplain mock plan with AST-based estimates
- Update STATE.scm: overall-completion 100 -> 75 (honest)
- Fix workspace authors field
- Replace/remove bincode pre-release dependency"
```

Then push:
```bash
git push origin main
git push gitlab main
```
