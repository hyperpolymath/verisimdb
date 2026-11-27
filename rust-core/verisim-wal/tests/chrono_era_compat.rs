// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! WAL entries written before the chrono -> `time` migration must still decode,
//! and entries written now must be byte-identical to what chrono-era code wrote.
//!
//! The fixtures below were produced by `WalEntry::serialize` and
//! `serde_json::to_string(&WalEntry)` on the chrono-based code (main at
//! afced12), one per fractional-second precision class.

use verisim_time::Timestamp;
use verisim_wal::{WalEntry, WalModality, WalOperation};

struct Fixture {
    /// The `DateTime<Utc>` the chrono-era entry was built from.
    timestamp: &'static str,
    /// Unix milliseconds stored in the binary entry.
    millis: i64,
    /// Full on-disk entry: `[entry_length][crc32][inner...]`.
    hex: &'static str,
    /// `serde_json::to_string(&entry)`.
    json: &'static str,
    operation: WalOperation,
    modality: WalModality,
}

const FIXTURES: &[Fixture] = &[
    Fixture {
        timestamp: "2026-11-18T09:30:00.250Z",
        millis: 1_794_994_200_250,
        hex: "2c000000dceab4f82800000000000000badefdeda10100000004070000006f637461642d30070000007b2276223a307d",
        json: r#"{"sequence":40,"timestamp":"2026-11-18T09:30:00.250Z","operation":"Insert","modality":"Document","entity_id":"octad-0","payload":[123,34,118,34,58,48,125]}"#,
        operation: WalOperation::Insert,
        modality: WalModality::Document,
    },
    Fixture {
        timestamp: "2026-11-18T09:31:00.250123Z",
        millis: 1_794_994_260_250,
        hex: "2c000000e312099d29000000000000001ac9feeda10100000105070000006f637461642d31070000007b2276223a317d",
        json: r#"{"sequence":41,"timestamp":"2026-11-18T09:31:00.250123Z","operation":"Update","modality":"Temporal","entity_id":"octad-1","payload":[123,34,118,34,58,49,125]}"#,
        operation: WalOperation::Update,
        modality: WalModality::Temporal,
    },
    Fixture {
        timestamp: "2026-11-18T09:32:00.250123456Z",
        millis: 1_794_994_320_250,
        hex: "2c000000aa08503a2a000000000000007ab3ffeda10100000206070000006f637461642d32070000007b2276223a327d",
        json: r#"{"sequence":42,"timestamp":"2026-11-18T09:32:00.250123456Z","operation":"Delete","modality":"Provenance","entity_id":"octad-2","payload":[123,34,118,34,58,50,125]}"#,
        operation: WalOperation::Delete,
        modality: WalModality::Provenance,
    },
    Fixture {
        timestamp: "2026-11-18T09:33:00Z",
        millis: 1_794_994_380_000,
        hex: "25000000dc75833c2b00000000000000e09c00eea101000003ff070000006f637461642d3300000000",
        json: r#"{"sequence":43,"timestamp":"2026-11-18T09:33:00Z","operation":"Checkpoint","modality":"All","entity_id":"octad-3","payload":[]}"#,
        operation: WalOperation::Checkpoint,
        modality: WalModality::All,
    },
];

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

fn entry(i: usize, f: &Fixture) -> WalEntry {
    WalEntry {
        sequence: 40 + i as u64,
        timestamp: Timestamp::parse_rfc3339(f.timestamp).unwrap(),
        operation: f.operation,
        modality: f.modality,
        entity_id: format!("octad-{i}"),
        payload: if f.operation == WalOperation::Checkpoint {
            vec![]
        } else {
            format!("{{\"v\":{i}}}").into_bytes()
        },
    }
}

#[test]
fn binary_entries_are_byte_identical_to_chrono_era() {
    for (i, f) in FIXTURES.iter().enumerate() {
        assert_eq!(entry(i, f).serialize(), unhex(f.hex), "{}", f.timestamp);
    }
}

#[test]
fn chrono_era_binary_entries_decode() {
    for (i, f) in FIXTURES.iter().enumerate() {
        let bytes = unhex(f.hex);
        let len = u32::from_le_bytes(bytes[..4].try_into().unwrap());
        let decoded = WalEntry::deserialize(&bytes[4..], len).unwrap();
        // The binary format stores milliseconds; sub-millisecond digits were
        // dropped on write before the migration too.
        assert_eq!(decoded.timestamp.unix_millis(), f.millis, "{}", f.timestamp);
        assert_eq!(
            decoded.timestamp,
            Timestamp::from_unix_millis(f.millis).unwrap()
        );
        let expected = WalEntry {
            timestamp: decoded.timestamp,
            ..entry(i, f)
        };
        assert_eq!(decoded, expected);
        // Re-encoding what was read reproduces the original bytes.
        assert_eq!(decoded.serialize(), bytes);
    }
}

#[test]
fn json_entries_round_trip_byte_identically() {
    for (i, f) in FIXTURES.iter().enumerate() {
        let read: WalEntry = serde_json::from_str(f.json).unwrap();
        assert_eq!(read, entry(i, f), "{}", f.timestamp);
        assert_eq!(serde_json::to_string(&read).unwrap(), f.json);
    }
}
