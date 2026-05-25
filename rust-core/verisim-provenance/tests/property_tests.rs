// SPDX-License-Identifier: MPL-2.0
//! Property-based tests for verisim-provenance.
//!
//! Hash-chain integrity is the central invariant.  These properties
//! exercise it across arbitrary chain lengths, event-type sequences,
//! and actor distributions.

use proptest::prelude::*;
use tokio::runtime::Runtime;
use verisim_provenance::{InMemoryProvenanceStore, ProvenanceEventType, ProvenanceStore};

fn rt() -> Runtime {
    Runtime::new().expect("tokio runtime")
}

fn event_type_strategy() -> impl Strategy<Value = ProvenanceEventType> {
    prop_oneof![
        Just(ProvenanceEventType::Created),
        Just(ProvenanceEventType::Modified),
        Just(ProvenanceEventType::Imported),
        Just(ProvenanceEventType::Normalized),
        Just(ProvenanceEventType::DriftRepaired),
        Just(ProvenanceEventType::Deleted),
        Just(ProvenanceEventType::Merged),
    ]
}

proptest! {
    /// Round-trip: after N appends, get_chain returns exactly N records.
    #[test]
    fn prop_chain_length_matches_appends(
        entity in "[a-z]{1,16}",
        n in 1usize..30
    ) {
        let rt = rt();
        let store = InMemoryProvenanceStore::new();

        rt.block_on(async {
            for i in 0..n {
                let et = if i == 0 {
                    ProvenanceEventType::Created
                } else {
                    ProvenanceEventType::Modified
                };
                store
                    .record_event(&entity, et, "bot", None, "step")
                    .await
                    .unwrap();
            }
            let chain = store.get_chain(&entity).await.unwrap();
            prop_assert_eq!(chain.len(), n);
            Ok(())
        })?;
    }

    /// Hash-chain integrity: verify_chain returns true for an
    /// untampered chain regardless of length, actor diversity, or
    /// event-type sequence.
    #[test]
    fn prop_verify_chain_untampered(
        entity in "[a-z]{1,16}",
        events in proptest::collection::vec(event_type_strategy(), 1..20),
        actors in proptest::collection::vec("[a-z]{1,8}", 1..20)
    ) {
        let rt = rt();
        let store = InMemoryProvenanceStore::new();

        rt.block_on(async {
            for (i, ev) in events.iter().enumerate() {
                let actor = actors.get(i % actors.len()).cloned().unwrap_or_else(|| "default".to_string());
                // First event must be Created for sensible semantics,
                // but the store accepts any event-type for the first.
                let et = if i == 0 {
                    ProvenanceEventType::Created
                } else {
                    ev.clone()
                };
                store
                    .record_event(&entity, et, &actor, None, "step")
                    .await
                    .unwrap();
            }
            prop_assert!(store.verify_chain(&entity).await.unwrap());
            Ok(())
        })?;
    }

    /// Origin is monotonic: after any sequence of appends, origin/0
    /// always returns the first record (the one with parent of genesis).
    #[test]
    fn prop_origin_is_first(
        entity in "[a-z]{1,16}",
        first_actor in "[a-z]{1,8}",
        rest in proptest::collection::vec("[a-z]{1,8}", 0..10)
    ) {
        let rt = rt();
        let store = InMemoryProvenanceStore::new();

        rt.block_on(async {
            store
                .record_event(&entity, ProvenanceEventType::Created, &first_actor, None, "origin")
                .await
                .unwrap();
            for actor in &rest {
                store
                    .record_event(&entity, ProvenanceEventType::Modified, actor, None, "edit")
                    .await
                    .unwrap();
            }
            let origin = store.get_origin(&entity).await.unwrap().unwrap();
            prop_assert_eq!(origin.actor, first_actor);
            prop_assert_eq!(origin.event_type, ProvenanceEventType::Created);
            Ok(())
        })?;
    }

    /// Latest tracks the last append: after recording N events, latest/0
    /// returns the Nth one.
    #[test]
    fn prop_latest_is_last_appended(
        entity in "[a-z]{1,16}",
        actors in proptest::collection::vec("[a-z]{1,8}", 2..10)
    ) {
        let rt = rt();
        let store = InMemoryProvenanceStore::new();

        rt.block_on(async {
            for (i, actor) in actors.iter().enumerate() {
                let et = if i == 0 {
                    ProvenanceEventType::Created
                } else {
                    ProvenanceEventType::Modified
                };
                store
                    .record_event(&entity, et, actor, None, "step")
                    .await
                    .unwrap();
            }
            let latest = store.get_latest(&entity).await.unwrap().unwrap();
            prop_assert_eq!(&latest.actor, actors.last().unwrap());
            Ok(())
        })?;
    }

    /// search_by_actor count invariant: total records returned for an
    /// actor equals the number of events that actor was responsible for
    /// across all entities.
    #[test]
    fn prop_search_by_actor_count(
        target_actor in "[a-z]{1,8}",
        entries in proptest::collection::vec(
            ("[a-z]{1,16}", "[a-z]{1,8}"),
            1..15
        )
    ) {
        let rt = rt();
        let store = InMemoryProvenanceStore::new();
        let expected = entries.iter().filter(|(_, a)| *a == target_actor).count();

        rt.block_on(async {
            for (entity, actor) in &entries {
                store
                    .record_event(entity, ProvenanceEventType::Created, actor, None, "step")
                    .await
                    .unwrap();
            }
            let results = store.search_by_actor(&target_actor).await.unwrap();
            prop_assert_eq!(results.len(), expected);
            for (_, record) in &results {
                prop_assert_eq!(&record.actor, &target_actor);
            }
            Ok(())
        })?;
    }

    /// Delete isolation: deleting one entity's chain leaves all other
    /// entities untouched.
    #[test]
    fn prop_delete_chain_is_isolated(
        keep_entity in "[a-z]{1,16}",
        drop_entity in "[a-z]{1,16}"
    ) {
        prop_assume!(keep_entity != drop_entity);
        let rt = rt();
        let store = InMemoryProvenanceStore::new();

        rt.block_on(async {
            store
                .record_event(&keep_entity, ProvenanceEventType::Created, "a", None, "keep")
                .await
                .unwrap();
            store
                .record_event(&drop_entity, ProvenanceEventType::Created, "a", None, "drop")
                .await
                .unwrap();

            store.delete_chain(&drop_entity).await.unwrap();
            prop_assert!(store.get_origin(&keep_entity).await.unwrap().is_some());
            prop_assert!(store.get_origin(&drop_entity).await.unwrap().is_none());
            Ok(())
        })?;
    }
}
