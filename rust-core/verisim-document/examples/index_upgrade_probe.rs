// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//! Two-process index upgrade probe. See tests/tantivy-upgrade.sh.

use verisim_document::{Document, DocumentStore, TantivyDocumentStore};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 || !["write", "read"].contains(&args[1].as_str()) {
        return Err("usage: index_upgrade_probe write|read INDEX_DIRECTORY".into());
    }
    let store = TantivyDocumentStore::persistent(&args[2])?;
    let original = Document::new("upgrade-fixture", "Authoring α", "provenance café scenario");
    if args[1] == "write" {
        store.index(&original).await?;
        store.commit().await?;
    } else {
        let read = store.get(&original.id).await?.ok_or("document missing")?;
        assert_eq!(read.id, original.id);
        assert_eq!(read.title, original.title);
        assert_eq!(read.body, original.body);
        let hits = store.search("provenance", 10).await?;
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].id, original.id);
        store.delete(&original.id).await?;
        store.commit().await?;
        assert!(store.search("provenance", 10).await?.is_empty());
    }
    Ok(())
}
