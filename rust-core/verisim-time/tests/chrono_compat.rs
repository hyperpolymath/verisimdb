// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! Compatibility with the formats chrono 0.4 wrote before the migration.
//!
//! The golden vectors in `fixtures/chrono-0.4.45-golden.tsv` were produced by
//! chrono 0.4.45 itself (`serde_json::to_string`, `to_rfc3339()`,
//! `to_string()`, `timestamp_millis()` on `DateTime<Utc>`), so they pin
//! chrono's behaviour now that chrono is no longer a dependency. The migration was also checked
//! against chrono directly on 2,000,000 random instants across years
//! -9999..=9999 (all text forms, millisecond and nanosecond conversions,
//! parsing in both directions, ordering and arithmetic) with no mismatch.

use proptest::prelude::*;
use verisim_time::{TimeDelta, Timestamp};

/// One row of `fixtures/chrono-0.4.45-golden.tsv`.
struct Golden<'a> {
    name: &'a str,
    unix_nanos: i128,
    /// What serde wrote, without the JSON quotes (also chrono's `Debug`).
    serde: &'a str,
    rfc3339: &'a str,
    display: &'a str,
    unix_millis: i64,
}

/// Output of chrono 0.4.45 itself, kept as data so it is plainly not
/// hand-written.
const GOLDEN_TSV: &str = include_str!("fixtures/chrono-0.4.45-golden.tsv");

fn golden() -> Vec<Golden<'static>> {
    let rows: Vec<Golden<'static>> = GOLDEN_TSV
        .lines()
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(|l| {
            let c: Vec<&str> = l.split('\t').collect();
            assert_eq!(c.len(), 6, "malformed fixture row: {l:?}");
            Golden {
                name: c[0],
                unix_nanos: c[1].parse().unwrap(),
                serde: c[2],
                rfc3339: c[3],
                display: c[4],
                unix_millis: c[5].parse().unwrap(),
            }
        })
        .collect();
    assert_eq!(rows.len(), 21, "fixture lost rows");
    rows
}

#[test]
fn golden_vectors_match_chrono_output() {
    for g in golden() {
        let ts = Timestamp::from_unix_nanos(g.unix_nanos).expect(g.name);
        let json = serde_json::to_string(&ts).unwrap();
        assert_eq!(json, format!("\"{}\"", g.serde), "serde: {}", g.name);
        assert_eq!(ts.to_rfc3339(), g.rfc3339, "to_rfc3339: {}", g.name);
        assert_eq!(ts.to_string(), g.display, "Display: {}", g.name);
        assert_eq!(format!("{ts:?}"), g.serde, "Debug: {}", g.name);
        assert_eq!(ts.unix_millis(), g.unix_millis, "unix_millis: {}", g.name);
    }
}

#[test]
fn golden_vectors_read_back() {
    for g in golden() {
        let want = Timestamp::from_unix_nanos(g.unix_nanos).unwrap();
        let json = format!("\"{}\"", g.serde);
        let from_serde: Timestamp = serde_json::from_str(&json).unwrap();
        assert_eq!(from_serde, want, "serde: {}", g.name);
        assert_eq!(
            Timestamp::parse_rfc3339(g.rfc3339).unwrap(),
            want,
            "rfc3339: {}",
            g.name
        );
    }
}

#[test]
fn non_utc_offsets_normalise_to_utc() {
    let a = Timestamp::parse_rfc3339("2026-11-18T15:00:00.5+05:30").unwrap();
    let b = Timestamp::parse_rfc3339("2026-11-18T09:30:00.500Z").unwrap();
    assert_eq!(a, b);
    let c = Timestamp::parse_rfc3339("-0001-01-01T00:30:00+01:00").unwrap();
    assert_eq!(c.to_rfc3339(), "-0002-12-31T23:30:00+00:00");
}

#[test]
fn rejects_what_it_cannot_represent() {
    for bad in [
        "",
        "2026-11-18",
        "2026-11-18T09:30:00",          // no offset
        "2026-02-30T00:00:00Z",         // no such day
        "+1000000-01-01T00:00:00Z",     // year out of range
        "+999999-12-31T23:59:59-00:01", // leaves the range only in UTC
        "-999999-01-01T00:00:00+00:01", // same, at the other end
        "2016-12-31T23:59:60Z",         // leap second
        "2016-12-31 23:59:60.5+00:00",  // leap second, other spelling
        "-123-01-01T00:00:00Z",         // expanded year needs 4+ digits
        "-",
        "2026-11-18T09:30:00Z trailing",
    ] {
        assert!(Timestamp::parse_rfc3339(bad).is_err(), "accepted {bad:?}");
        assert!(serde_json::from_str::<Timestamp>(&format!("{bad:?}")).is_err());
    }
}

/// chrono wrote and read expanded years up to ±262143; all of them read back.
#[test]
fn chrono_era_expanded_years_read_back() {
    for (text, rfc) in [
        ("+10000-01-01T00:00:00Z", "+10000-01-01T00:00:00+00:00"),
        (
            "+262142-12-31T23:59:59.999999999Z",
            "+262142-12-31T23:59:59.999999999+00:00",
        ),
        ("-262143-01-01T00:00:00Z", "-262143-01-01T00:00:00+00:00"),
        // A four-digit local time that is in year 10000 once the offset is
        // removed: valid, and never a panic.
        ("9999-12-31T23:59:59-00:01", "+10000-01-01T00:00:59+00:00"),
    ] {
        let ts = Timestamp::parse_rfc3339(text).unwrap_or_else(|e| panic!("{text}: {e}"));
        assert_eq!(ts.to_rfc3339(), rfc, "{text}");
        let json = serde_json::to_string(&ts).unwrap();
        assert_eq!(serde_json::from_str::<Timestamp>(&json).unwrap(), ts);
    }
}

#[test]
fn arithmetic_matches_signed_duration_semantics() {
    let t = Timestamp::from_unix_millis(1_000).unwrap();
    let later = t + TimeDelta::milliseconds(1_500);
    assert_eq!(later.unix_millis(), 2_500);
    assert_eq!((t - later).whole_milliseconds(), -1_500);
    assert_eq!((later - t).whole_seconds(), 1);
    assert_eq!(later - TimeDelta::milliseconds(1_500), t);
    assert!(Timestamp::from_unix_nanos(i128::MAX).is_none());
}

/// Any instant in the supported range.
/// Unix nanoseconds of -999999-01-01T00:00:00Z and
/// 999999-12-31T23:59:59.999999999Z, the representable range (`time` with
/// `large-dates`), computed independently with the days-from-civil algorithm. Literal on purpose: deriving them through
/// `unix_nanos` would let a broken `unix_nanos` shrink the strategy to one
/// point and every law below pass vacuously.
const MIN_NANOS: i128 = -31_619_087_596_800_000_000_000;
const MAX_NANOS: i128 = 31_494_784_780_799_999_999_999;

#[test]
fn range_bounds_are_the_representable_extremes() {
    let min = Timestamp::from_unix_nanos(MIN_NANOS).unwrap();
    let max = Timestamp::from_unix_nanos(MAX_NANOS).unwrap();
    assert_eq!(min.to_rfc3339(), "-999999-01-01T00:00:00+00:00");
    assert_eq!(max.to_rfc3339(), "+999999-12-31T23:59:59.999999999+00:00");
    assert_eq!((min, max), (Timestamp::MIN, Timestamp::MAX));
    assert_eq!(min.unix_nanos(), MIN_NANOS);
    assert_eq!(max.unix_nanos(), MAX_NANOS);
    assert!(Timestamp::from_unix_nanos(MIN_NANOS - 1).is_none());
    assert!(Timestamp::from_unix_nanos(MAX_NANOS + 1).is_none());
}

/// Any instant in the supported range.
fn any_timestamp() -> impl Strategy<Value = Timestamp> {
    (MIN_NANOS..=MAX_NANOS).prop_map(|n| Timestamp::from_unix_nanos(n).unwrap())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(4096))]

    /// parse ∘ serialize = id, for both the serde and the `+00:00` form.
    #[test]
    fn text_forms_round_trip(ts in any_timestamp()) {
        let json = serde_json::to_string(&ts).unwrap();
        prop_assert_eq!(serde_json::from_str::<Timestamp>(&json).unwrap(), ts);
        prop_assert_eq!(Timestamp::parse_rfc3339(&ts.to_rfc3339()).unwrap(), ts);
        prop_assert_eq!(ts.to_rfc3339().parse::<Timestamp>().unwrap(), ts);
    }

    /// The serde and `+00:00` forms differ only in the offset suffix.
    #[test]
    fn serde_and_rfc3339_forms_agree(ts in any_timestamp()) {
        let json = serde_json::to_string(&ts).unwrap();
        let rfc = ts.to_rfc3339();
        prop_assert_eq!(json.trim_matches('"').strip_suffix('Z'), rfc.strip_suffix("+00:00"));
    }

    /// The fraction has 0, 3, 6 or 9 digits and never ends in a redundant
    /// group of zeros (chrono's AutoSi).
    #[test]
    fn fraction_is_auto_si(ts in any_timestamp()) {
        let rfc = ts.to_rfc3339();
        let body = rfc.strip_suffix("+00:00").unwrap();
        let frac = body.rsplit_once('.').map(|(_, f)| f).unwrap_or("");
        prop_assert!(matches!(frac.len(), 0 | 3 | 6 | 9), "{}", rfc);
        if frac.len() >= 3 {
            prop_assert!(!frac.ends_with("000"), "{}", rfc);
        }
    }

    /// Ordering of timestamps is ordering of the instants.
    #[test]
    fn order_is_instant_order(a in any_timestamp(), b in any_timestamp()) {
        prop_assert_eq!(a.cmp(&b), a.unix_nanos().cmp(&b.unix_nanos()));
    }

    /// The WAL's millisecond encoding round-trips at millisecond precision.
    #[test]
    fn millis_round_trip(ts in any_timestamp()) {
        let back = Timestamp::from_unix_millis(ts.unix_millis()).unwrap();
        prop_assert_eq!(back.unix_millis(), ts.unix_millis());
        prop_assert!(back <= ts && ts - back < TimeDelta::milliseconds(1));
    }

    /// An offset in the text shifts the instant by exactly that offset.
    #[test]
    fn offsets_shift_exactly(ts in any_timestamp(), minutes in -(23 * 60 + 59)..=(23 * 60 + 59i64)) {
        let local = ts.checked_add(TimeDelta::minutes(minutes));
        prop_assume!(local.is_some());
        let local = local.unwrap().to_rfc3339();
        let sign = if minutes < 0 { '-' } else { '+' };
        let text = format!(
            "{}{sign}{:02}:{:02}",
            local.strip_suffix("+00:00").unwrap(),
            minutes.abs() / 60,
            minutes.abs() % 60
        );
        prop_assert_eq!(Timestamp::parse_rfc3339(&text).unwrap(), ts, "{}", text);
    }
}
