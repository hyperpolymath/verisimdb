// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! Temporal data written before the chrono -> `time` migration must still be
//! readable, and what is written now must be byte-identical.
//!
//! `RedbVersionStore` persists each entity's `BTreeMap<u64, Version<T>>` as
//! JSON through `TypedStore::put` under the key `ver:{entity_id}`. The fixtures
//! below are `serde_json::to_vec` of those values on the chrono-based code
//! (main at afced12), one version per fractional-second precision class.

use std::collections::BTreeMap;

use verisim_temporal::{TimePoint, TimeRange, Version};
use verisim_time::Timestamp;

const CHRONO_ERA_HISTORY: &str = r#"{"1":{"version":1,"timestamp":"2026-11-18T09:30:00.250Z","data":{"name":"Alice","rev":1},"author":"fixture","message":"rev 1"},"2":{"version":2,"timestamp":"2026-11-18T09:31:00.250123Z","data":{"name":"Alice","rev":2},"author":"fixture","message":null},"3":{"version":3,"timestamp":"2026-11-18T09:32:00.250123456Z","data":{"name":"Alice","rev":3},"author":"fixture","message":"rev 3"},"4":{"version":4,"timestamp":"2026-11-18T09:33:00Z","data":{"name":"Alice","rev":4},"author":"fixture","message":null}}"#;
const CHRONO_ERA_RANGE: &str =
    r#"{"start":"2026-11-18T09:30:00.250Z","end":"2026-11-18T09:33:00Z"}"#;
const CHRONO_ERA_TIMEPOINT: &str =
    r#"{"time":"2026-11-18T09:32:00.250123456Z","value":3.5,"labels":{}}"#;

const STAMPS: [&str; 4] = [
    "2026-11-18T09:30:00.250Z",
    "2026-11-18T09:31:00.250123Z",
    "2026-11-18T09:32:00.250123456Z",
    "2026-11-18T09:33:00Z",
];

type History = BTreeMap<u64, Version<serde_json::Value>>;

fn ts(s: &str) -> Timestamp {
    Timestamp::parse_rfc3339(s).unwrap()
}

#[test]
fn chrono_era_history_reads_back_with_full_precision() {
    let history: History = serde_json::from_str(CHRONO_ERA_HISTORY).unwrap();
    assert_eq!(history.len(), 4);
    for (i, stamp) in STAMPS.iter().enumerate() {
        let v = &history[&(i as u64 + 1)];
        assert_eq!(v.timestamp, ts(stamp));
        assert_eq!(v.data["rev"], i + 1);
    }
    // Nanosecond precision survives the read.
    assert_eq!(
        history[&3].timestamp.unix_nanos() % 1_000_000_000,
        250_123_456
    );
}

#[test]
fn history_reserializes_byte_identically() {
    let history: History = serde_json::from_str(CHRONO_ERA_HISTORY).unwrap();
    assert_eq!(
        String::from_utf8(serde_json::to_vec(&history).unwrap()).unwrap(),
        CHRONO_ERA_HISTORY
    );
}

#[test]
fn range_and_timepoint_round_trip_byte_identically() {
    let range: TimeRange = serde_json::from_str(CHRONO_ERA_RANGE).unwrap();
    assert!(range.contains(&ts(STAMPS[1])));
    assert!(!range.contains(&ts(STAMPS[3]))); // end is exclusive
    assert_eq!(serde_json::to_string(&range).unwrap(), CHRONO_ERA_RANGE);

    let tp: TimePoint<f64> = serde_json::from_str(CHRONO_ERA_TIMEPOINT).unwrap();
    assert_eq!(tp.time, ts(STAMPS[2]));
    assert_eq!(serde_json::to_string(&tp).unwrap(), CHRONO_ERA_TIMEPOINT);
}

/// End to end: chrono-era bytes in a redb file, opened by the current
/// `RedbVersionStore` and queried by time.
#[cfg(feature = "redb-backend")]
#[tokio::test]
async fn redb_store_opens_chrono_era_data() {
    use verisim_storage::{RedbBackend, StorageBackend};
    use verisim_temporal::{RedbVersionStore, TemporalStore};

    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("chrono-era.redb");
    {
        let backend = RedbBackend::open(&path).unwrap();
        backend
            .put(b"ver:alice", CHRONO_ERA_HISTORY.as_bytes())
            .await
            .unwrap();
    }

    let store = RedbVersionStore::<serde_json::Value>::open(&path)
        .await
        .unwrap();
    let latest = store.latest("alice").await.unwrap().unwrap();
    assert_eq!(latest.version, 4);
    assert_eq!(latest.timestamp, ts(STAMPS[3]));

    // One nanosecond before version 3 resolves to version 2; at it, to 3.
    let v3 = ts(STAMPS[2]);
    let before = store
        .at_time("alice", v3 - verisim_time::TimeDelta::nanoseconds(1))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(before.version, 2);
    let at = store.at_time("alice", v3).await.unwrap().unwrap();
    assert_eq!(at.version, 3);

    // Appending re-persists the whole history: the old versions must be
    // written back exactly as chrono wrote them.
    store
        .append("alice", serde_json::json!({"rev": 5}), "now", None)
        .await
        .unwrap();
    drop(store);
    let backend = RedbBackend::open(&path).unwrap();
    let raw = backend.get(b"ver:alice").await.unwrap().unwrap();
    let rewritten: serde_json::Value = serde_json::from_slice(&raw).unwrap();
    let original: serde_json::Value = serde_json::from_str(CHRONO_ERA_HISTORY).unwrap();
    for k in ["1", "2", "3", "4"] {
        assert_eq!(rewritten[k], original[k], "version {k}");
    }
}
