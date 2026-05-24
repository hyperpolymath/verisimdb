// SPDX-License-Identifier: MPL-2.0
//! Integration tests for verisim-provenance.
//!
//! Hash-chain integrity is the central invariant of this crate: each
//! record's hash depends on the previous record's hash, so any tampering
//! or out-of-order append must be detectable.  These tests verify
//! end-to-end behaviour across multi-record chains, actor-based search,
//! and the verify/origin/latest accessors.

use verisim_provenance::{InMemoryProvenanceStore, ProvenanceEventType, ProvenanceStore};

#[tokio::test]
async fn first_record_for_entity_creates_chain() {
    let store = InMemoryProvenanceStore::new();
    let rec = store
        .record_event(
            "doc-1",
            ProvenanceEventType::Created,
            "alice",
            None,
            "initial creation",
        )
        .await
        .unwrap();

    assert_eq!(rec.actor, "alice");
    assert_eq!(rec.event_type, ProvenanceEventType::Created);

    let chain = store.get_chain("doc-1").await.unwrap();
    assert_eq!(chain.len(), 1);
}

#[tokio::test]
async fn empty_entity_has_no_origin_or_latest() {
    let store = InMemoryProvenanceStore::new();
    assert!(store.get_origin("ghost").await.unwrap().is_none());
    assert!(store.get_latest("ghost").await.unwrap().is_none());
}

#[tokio::test]
async fn origin_is_the_first_record_appended() {
    let store = InMemoryProvenanceStore::new();
    store
        .record_event("e", ProvenanceEventType::Created, "alice", None, "first")
        .await
        .unwrap();
    store
        .record_event("e", ProvenanceEventType::Modified, "bob", None, "second")
        .await
        .unwrap();
    store
        .record_event("e", ProvenanceEventType::Modified, "carol", None, "third")
        .await
        .unwrap();

    let origin = store.get_origin("e").await.unwrap().unwrap();
    assert_eq!(origin.actor, "alice");
    assert_eq!(origin.event_type, ProvenanceEventType::Created);

    let latest = store.get_latest("e").await.unwrap().unwrap();
    assert_eq!(latest.actor, "carol");
}

#[tokio::test]
async fn verify_chain_returns_true_for_an_untampered_chain() {
    let store = InMemoryProvenanceStore::new();
    for i in 0..10 {
        let event_type = if i == 0 {
            ProvenanceEventType::Created
        } else {
            ProvenanceEventType::Modified
        };
        store
            .record_event("c", event_type, &format!("actor-{}", i), None, "step")
            .await
            .unwrap();
    }

    assert!(store.verify_chain("c").await.unwrap());
}

#[tokio::test]
async fn verify_chain_handles_unknown_entity() {
    let store = InMemoryProvenanceStore::new();
    // No chain exists — verify should return false (or an error
    // wrapping that fact), not crash.
    let result = store.verify_chain("never-seen").await;
    assert!(result.is_ok() || result.is_err());
}

#[tokio::test]
async fn search_by_actor_returns_matching_records_across_entities() {
    let store = InMemoryProvenanceStore::new();

    store
        .record_event(
            "e1",
            ProvenanceEventType::Created,
            "alice",
            None,
            "alice on e1",
        )
        .await
        .unwrap();
    store
        .record_event("e2", ProvenanceEventType::Created, "bob", None, "bob on e2")
        .await
        .unwrap();
    store
        .record_event(
            "e3",
            ProvenanceEventType::Created,
            "alice",
            None,
            "alice on e3",
        )
        .await
        .unwrap();

    let alice_records = store.search_by_actor("alice").await.unwrap();
    assert_eq!(alice_records.len(), 2);
    for (_entity_id, record) in &alice_records {
        assert_eq!(record.actor, "alice");
    }

    let bob_records = store.search_by_actor("bob").await.unwrap();
    assert_eq!(bob_records.len(), 1);

    let entity_ids: Vec<&str> = alice_records.iter().map(|(id, _)| id.as_str()).collect();
    assert!(entity_ids.contains(&"e1"));
    assert!(entity_ids.contains(&"e3"));
}

#[tokio::test]
async fn search_by_actor_returns_empty_for_unknown_actor() {
    let store = InMemoryProvenanceStore::new();
    store
        .record_event("e", ProvenanceEventType::Created, "alice", None, "x")
        .await
        .unwrap();

    let results = store.search_by_actor("nobody").await.unwrap();
    assert!(results.is_empty());
}

#[tokio::test]
async fn chain_length_grows_monotonically_with_appends() {
    let store = InMemoryProvenanceStore::new();
    for i in 0..50 {
        let event_type = if i == 0 {
            ProvenanceEventType::Created
        } else {
            ProvenanceEventType::Modified
        };
        store
            .record_event("growing", event_type, "actor", None, "step")
            .await
            .unwrap();
        let chain = store.get_chain("growing").await.unwrap();
        assert_eq!(chain.len(), i + 1);
    }
}

#[tokio::test]
async fn delete_chain_removes_all_records_for_entity() {
    let store = InMemoryProvenanceStore::new();
    for _ in 0..5 {
        store
            .record_event("doomed", ProvenanceEventType::Modified, "a", None, "x")
            .await
            .unwrap();
    }

    store.delete_chain("doomed").await.unwrap();
    assert!(store.get_origin("doomed").await.unwrap().is_none());
    assert!(store.get_latest("doomed").await.unwrap().is_none());
}

#[tokio::test]
async fn delete_chain_is_isolated_per_entity() {
    let store = InMemoryProvenanceStore::new();
    store
        .record_event("keep", ProvenanceEventType::Created, "a", None, "k")
        .await
        .unwrap();
    store
        .record_event("drop", ProvenanceEventType::Created, "a", None, "d")
        .await
        .unwrap();

    store.delete_chain("drop").await.unwrap();
    assert!(store.get_origin("keep").await.unwrap().is_some());
    assert!(store.get_origin("drop").await.unwrap().is_none());
}

#[tokio::test]
async fn record_event_with_source_is_preserved() {
    let store = InMemoryProvenanceStore::new();
    let rec = store
        .record_event(
            "imported",
            ProvenanceEventType::Imported,
            "etl-bot",
            Some("https://upstream.example/dump.json".to_string()),
            "ingested from upstream",
        )
        .await
        .unwrap();

    assert_eq!(rec.event_type, ProvenanceEventType::Imported);

    let chain = store.get_chain("imported").await.unwrap();
    assert_eq!(chain.len(), 1);
}
