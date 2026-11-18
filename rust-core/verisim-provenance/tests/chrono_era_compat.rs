// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! Provenance chains written before the chrono -> `time` migration must still
//! verify. `content_hash` is SHA-256 over JSON that embeds
//! `timestamp.to_rfc3339()`, so a single changed byte in that string would
//! break every existing chain.
//!
//! The fixture is `serde_json::to_string(&ProvenanceChain)` from the
//! chrono-based code (main at afced12), with one record per fractional-second
//! precision class.

use verisim_provenance::{ProvenanceChain, ProvenanceRecord};

const CHRONO_ERA_CHAIN: &str = r#"{"entity_id":"octad-prov-1","records":[{"event_type":"Created","actor":"fixture-actor","timestamp":"2026-11-18T09:30:00.250Z","source":"import://fixture","description":"event 0","parent_hash":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","content_hash":"f2cface95af11874019680a974bf51fa4c4d1d7d82716417f5f93f6ce50d1127"},{"event_type":"Modified","actor":"fixture-actor","timestamp":"2026-11-18T09:31:00.250123Z","source":null,"description":"event 1","parent_hash":"f2cface95af11874019680a974bf51fa4c4d1d7d82716417f5f93f6ce50d1127","content_hash":"c47d7e19c8ade1872cc4ffd43cd741fda16b04d5f1f08c7d0da7f9df7cecaebc"},{"event_type":"Normalized","actor":"fixture-actor","timestamp":"2026-11-18T09:32:00.250123456Z","source":null,"description":"event 2","parent_hash":"c47d7e19c8ade1872cc4ffd43cd741fda16b04d5f1f08c7d0da7f9df7cecaebc","content_hash":"151bffa6ae4a5be4d2fdc9a1c41913673dedaf82e718243554599a0c0942badc"},{"event_type":{"Custom":"audit"},"actor":"fixture-actor","timestamp":"2026-11-18T09:33:00Z","source":null,"description":"event 3","parent_hash":"151bffa6ae4a5be4d2fdc9a1c41913673dedaf82e718243554599a0c0942badc","content_hash":"7bdc428ae34923de8d701806490209b19bba2520de6ec59e33e01c8cd5aec26d"}]}"#;

#[test]
fn chrono_era_chain_still_verifies() {
    let chain: ProvenanceChain = serde_json::from_str(CHRONO_ERA_CHAIN).unwrap();
    assert_eq!(chain.len(), 4);
    chain.verify().expect("pre-migration chain must verify");
    for r in &chain.records {
        assert!(r.verify(), "record {:?}", r.description);
    }
}

#[test]
fn recomputed_hashes_match_stored_hashes() {
    let chain: ProvenanceChain = serde_json::from_str(CHRONO_ERA_CHAIN).unwrap();
    for r in &chain.records {
        let h = ProvenanceRecord::compute_hash(
            &r.event_type,
            &r.actor,
            &r.timestamp,
            &r.source,
            &r.description,
            &r.parent_hash,
        );
        assert_eq!(h, r.content_hash, "{}", r.timestamp.to_rfc3339());
    }
}

#[test]
fn chain_reserializes_byte_identically() {
    let chain: ProvenanceChain = serde_json::from_str(CHRONO_ERA_CHAIN).unwrap();
    assert_eq!(serde_json::to_string(&chain).unwrap(), CHRONO_ERA_CHAIN);
}
