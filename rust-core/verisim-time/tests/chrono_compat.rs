// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! Compatibility with the formats chrono 0.4 wrote before the migration.
//!
//! The golden vectors below were produced by chrono 0.4.45 itself
//! (`serde_json::to_string`, `to_rfc3339()`, `to_string()`,
//! `timestamp_millis()` on `DateTime<Utc>`), so they pin chrono's behaviour
//! now that chrono is no longer a dependency. The migration was also checked
//! against chrono directly on 2,000,000 random instants across years
//! -9999..=9999 (all text forms, millisecond and nanosecond conversions,
//! parsing in both directions, ordering and arithmetic) with no mismatch.

use proptest::prelude::*;
use verisim_time::{TimeDelta, Timestamp};

struct Golden {
    name: &'static str,
    unix_nanos: i128,
    serde: &'static str,
    rfc3339: &'static str,
    display: &'static str,
    unix_millis: i64,
}

#[rustfmt::skip]
const GOLDEN: &[Golden] = &[
    Golden {
        name: "unix epoch",
        unix_nanos: 0,
        serde: "\"1970-01-01T00:00:00Z\"",
        rfc3339: "1970-01-01T00:00:00+00:00",
        display: "1970-01-01 00:00:00 UTC",
        unix_millis: 0,
    },
    Golden {
        name: "one nanosecond",
        unix_nanos: 1,
        serde: "\"1970-01-01T00:00:00.000000001Z\"",
        rfc3339: "1970-01-01T00:00:00.000000001+00:00",
        display: "1970-01-01 00:00:00.000000001 UTC",
        unix_millis: 0,
    },
    Golden {
        name: "one microsecond",
        unix_nanos: 1000,
        serde: "\"1970-01-01T00:00:00.000001Z\"",
        rfc3339: "1970-01-01T00:00:00.000001+00:00",
        display: "1970-01-01 00:00:00.000001 UTC",
        unix_millis: 0,
    },
    Golden {
        name: "one millisecond",
        unix_nanos: 1000000,
        serde: "\"1970-01-01T00:00:00.001Z\"",
        rfc3339: "1970-01-01T00:00:00.001+00:00",
        display: "1970-01-01 00:00:00.001 UTC",
        unix_millis: 1,
    },
    Golden {
        name: "one nanosecond before epoch",
        unix_nanos: -1,
        serde: "\"1969-12-31T23:59:59.999999999Z\"",
        rfc3339: "1969-12-31T23:59:59.999999999+00:00",
        display: "1969-12-31 23:59:59.999999999 UTC",
        unix_millis: -1,
    },
    Golden {
        name: "1.5 s",
        unix_nanos: 1500000000,
        serde: "\"1970-01-01T00:00:01.500Z\"",
        rfc3339: "1970-01-01T00:00:01.500+00:00",
        display: "1970-01-01 00:00:01.500 UTC",
        unix_millis: 1500,
    },
    Golden {
        name: "realistic ms (WAL-era)",
        unix_nanos: 1763458200250000000,
        serde: "\"2025-11-18T09:30:00.250Z\"",
        rfc3339: "2025-11-18T09:30:00.250+00:00",
        display: "2025-11-18 09:30:00.250 UTC",
        unix_millis: 1763458200250,
    },
    Golden {
        name: "realistic us",
        unix_nanos: 1763458200250123000,
        serde: "\"2025-11-18T09:30:00.250123Z\"",
        rfc3339: "2025-11-18T09:30:00.250123+00:00",
        display: "2025-11-18 09:30:00.250123 UTC",
        unix_millis: 1763458200250,
    },
    Golden {
        name: "realistic ns",
        unix_nanos: 1763458200250123456,
        serde: "\"2025-11-18T09:30:00.250123456Z\"",
        rfc3339: "2025-11-18T09:30:00.250123456+00:00",
        display: "2025-11-18 09:30:00.250123456 UTC",
        unix_millis: 1763458200250,
    },
    Golden {
        name: "ns with trailing zero",
        unix_nanos: 1763458200100000010,
        serde: "\"2025-11-18T09:30:00.100000010Z\"",
        rfc3339: "2025-11-18T09:30:00.100000010+00:00",
        display: "2025-11-18 09:30:00.100000010 UTC",
        unix_millis: 1763458200100,
    },
    Golden {
        name: "leap day 2024-02-29",
        unix_nanos: 1709164800000000000,
        serde: "\"2024-02-29T00:00:00Z\"",
        rfc3339: "2024-02-29T00:00:00+00:00",
        display: "2024-02-29 00:00:00 UTC",
        unix_millis: 1709164800000,
    },
    Golden {
        name: "leap day 2000-02-29",
        unix_nanos: 951782400000000000,
        serde: "\"2000-02-29T00:00:00Z\"",
        rfc3339: "2000-02-29T00:00:00+00:00",
        display: "2000-02-29 00:00:00 UTC",
        unix_millis: 951782400000,
    },
    Golden {
        name: "1900-03-01 (not a leap year)",
        unix_nanos: -2203891200000000000,
        serde: "\"1900-03-01T00:00:00Z\"",
        rfc3339: "1900-03-01T00:00:00+00:00",
        display: "1900-03-01 00:00:00 UTC",
        unix_millis: -2203891200000,
    },
    Golden {
        name: "year 0",
        unix_nanos: -62167219200000000000,
        serde: "\"0000-01-01T00:00:00Z\"",
        rfc3339: "0000-01-01T00:00:00+00:00",
        display: "0000-01-01 00:00:00 UTC",
        unix_millis: -62167219200000,
    },
    Golden {
        name: "year -1 (expanded form)",
        unix_nanos: -62198755200000000000,
        serde: "\"-0001-01-01T00:00:00Z\"",
        rfc3339: "-0001-01-01T00:00:00+00:00",
        display: "-0001-01-01 00:00:00 UTC",
        unix_millis: -62198755200000,
    },
    Golden {
        name: "year 9999 last ns",
        unix_nanos: 253402300799999999999,
        serde: "\"9999-12-31T23:59:59.999999999Z\"",
        rfc3339: "9999-12-31T23:59:59.999999999+00:00",
        display: "9999-12-31 23:59:59.999999999 UTC",
        unix_millis: 253402300799999,
    },
    Golden {
        name: "year -9999 first instant",
        unix_nanos: -377705116800000000000,
        serde: "\"-9999-01-01T00:00:00Z\"",
        rfc3339: "-9999-01-01T00:00:00+00:00",
        display: "-9999-01-01 00:00:00 UTC",
        unix_millis: -377705116800000,
    },
];

#[test]
fn golden_vectors_match_chrono_output() {
    for g in GOLDEN {
        let ts = Timestamp::from_unix_nanos(g.unix_nanos).expect(g.name);
        assert_eq!(
            serde_json::to_string(&ts).unwrap(),
            g.serde,
            "serde: {}",
            g.name
        );
        assert_eq!(ts.to_rfc3339(), g.rfc3339, "to_rfc3339: {}", g.name);
        assert_eq!(ts.to_string(), g.display, "Display: {}", g.name);
        assert_eq!(
            format!("{ts:?}"),
            g.serde.trim_matches('"'),
            "Debug: {}",
            g.name
        );
        assert_eq!(ts.unix_millis(), g.unix_millis, "unix_millis: {}", g.name);
    }
}

#[test]
fn golden_vectors_read_back() {
    for g in GOLDEN {
        let want = Timestamp::from_unix_nanos(g.unix_nanos).unwrap();
        let from_serde: Timestamp = serde_json::from_str(g.serde).unwrap();
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
        "2026-11-18T09:30:00",    // no offset
        "2026-02-30T00:00:00Z",   // no such day
        "+10000-01-01T00:00:00Z", // year out of range
        "-123-01-01T00:00:00Z",   // expanded year needs 4+ digits
        "-",
        "2026-11-18T09:30:00Z trailing",
    ] {
        assert!(Timestamp::parse_rfc3339(bad).is_err(), "accepted {bad:?}");
        assert!(serde_json::from_str::<Timestamp>(&format!("{bad:?}")).is_err());
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
fn any_timestamp() -> impl Strategy<Value = Timestamp> {
    let min = Timestamp::parse_rfc3339("-9999-01-01T00:00:00Z")
        .unwrap()
        .unix_nanos();
    let max = Timestamp::parse_rfc3339("9999-12-31T23:59:59.999999999Z")
        .unwrap()
        .unix_nanos();
    (min..=max).prop_map(|n| Timestamp::from_unix_nanos(n).unwrap())
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
