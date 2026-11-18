// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! UTC timestamps for VeriSimDB.
//!
//! [`Timestamp`] replaces `chrono::DateTime<chrono::Utc>` across the
//! workspace (RUSTSEC-2026-0543: chrono is unmaintained). It is a thin newtype
//! over [`time::UtcDateTime`] whose text forms are byte-for-byte the ones
//! chrono 0.4 produced, so data written before the migration stays readable
//! and hashes computed over formatted timestamps (provenance chains) still
//! verify.
//!
//! # Text formats
//!
//! All three forms print the fractional second the way chrono's
//! `SecondsFormat::AutoSi` does: nothing for a whole second, otherwise exactly
//! 3, 6 or 9 digits, whichever is the shortest exact representation.
//!
//! | Producer                            | Example                         |
//! |-------------------------------------|---------------------------------|
//! | `serde` / [`fmt::Debug`]            | `2026-11-18T09:30:00.250Z`      |
//! | [`Timestamp::to_rfc3339`]           | `2026-11-18T09:30:00.250+00:00` |
//! | [`fmt::Display`]                    | `2026-11-18 09:30:00.250 UTC`   |
//!
//! Years outside `0000..=9999` are written with an explicit sign and at least
//! four digits (`-0001`), as chrono did. The `time` crate's default range is
//! `-9999..=9999`.
//!
//! # Parsing
//!
//! [`Timestamp::parse_rfc3339`], [`FromStr`] and `serde` deserialization accept
//! RFC 3339 with any UTC offset (normalised to UTC), `Z` or `z`, any single
//! date/time separator (`T`, `t`, space) and any number of fractional digits
//! (digits beyond nanoseconds are truncated). This covers everything chrono
//! wrote. Differences from chrono's parser, none of which can arise from a
//! `Utc::now()` value:
//!
//! * years outside `-9999..=9999` are rejected (they are not representable);
//!   signed years inside it (`-0001-…`, ISO 8601 expanded form, which chrono
//!   wrote and read) are accepted, so every value this crate writes reads
//!   back;
//! * a leap second `23:59:60` is read as `23:59:59.999999999` rather than
//!   chrono's leap-second representation.

#![forbid(unsafe_code)]
#![warn(missing_docs)]

use std::fmt;
use std::ops::{Add, AddAssign, Sub, SubAssign};
use std::str::FromStr;

use serde::{de, Deserialize, Deserializer, Serialize, Serializer};
use time::format_description::well_known::Rfc3339;
use time::{OffsetDateTime, UtcDateTime};

/// A signed span of time, the replacement for `chrono::TimeDelta`
/// (`chrono::Duration`).
///
/// This is [`time::Duration`]. It is distinct from [`std::time::Duration`],
/// which is unsigned. Constructors: `TimeDelta::seconds(n)`,
/// `TimeDelta::milliseconds(n)`; accessors: `whole_seconds()`,
/// `whole_milliseconds()`.
pub use time::Duration as TimeDelta;

const NANOS_PER_MILLI: i128 = 1_000_000;

/// An instant in UTC with nanosecond precision.
///
/// See the [crate documentation](crate) for the text formats.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Timestamp(UtcDateTime);

impl Timestamp {
    /// 1970-01-01T00:00:00Z.
    pub const UNIX_EPOCH: Self = Self(UtcDateTime::UNIX_EPOCH);

    /// The current time, from the system clock.
    #[must_use]
    pub fn now() -> Self {
        Self(UtcDateTime::now())
    }

    /// Whole seconds since the Unix epoch, rounded towards negative infinity
    /// (chrono's `timestamp()`).
    #[must_use]
    pub const fn unix_seconds(self) -> i64 {
        self.0.unix_timestamp()
    }

    /// Milliseconds since the Unix epoch, rounded towards negative infinity
    /// (chrono's `timestamp_millis()`).
    #[must_use]
    pub const fn unix_millis(self) -> i64 {
        // |nanos| / 10^6 is far inside i64 for every representable year.
        self.0.unix_timestamp_nanos().div_euclid(NANOS_PER_MILLI) as i64
    }

    /// Nanoseconds since the Unix epoch.
    #[must_use]
    pub const fn unix_nanos(self) -> i128 {
        self.0.unix_timestamp_nanos()
    }

    /// Build from whole seconds since the Unix epoch, or `None` if out of range.
    #[must_use]
    pub fn from_unix_seconds(secs: i64) -> Option<Self> {
        UtcDateTime::from_unix_timestamp(secs).ok().map(Self)
    }

    /// Build from milliseconds since the Unix epoch, or `None` if out of range
    /// (chrono's `Utc.timestamp_millis_opt(ms).single()`).
    #[must_use]
    pub fn from_unix_millis(millis: i64) -> Option<Self> {
        Self::from_unix_nanos(i128::from(millis) * NANOS_PER_MILLI)
    }

    /// Build from nanoseconds since the Unix epoch, or `None` if out of range.
    #[must_use]
    pub fn from_unix_nanos(nanos: i128) -> Option<Self> {
        UtcDateTime::from_unix_timestamp_nanos(nanos).ok().map(Self)
    }

    /// Parse an RFC 3339 timestamp with any UTC offset; the result is the same
    /// instant in UTC. See the [crate documentation](crate) for what is
    /// accepted.
    pub fn parse_rfc3339(s: &str) -> Result<Self, ParseError> {
        match s.as_bytes().first() {
            Some(b'+' | b'-') => Self::parse_expanded_year(s),
            _ => Self::parse_four_digit_year(s),
        }
    }

    fn parse_four_digit_year(s: &str) -> Result<Self, ParseError> {
        OffsetDateTime::parse(s, &Rfc3339)
            .map(|dt| Self(dt.to_utc()))
            .map_err(|e| ParseError(ParseErrorKind::Syntax(e)))
    }

    /// Years outside `0000..=9999` are written in ISO 8601 expanded form
    /// (`-0001-…`, as chrono did), which RFC 3339 parsers reject. Parse them
    /// through a proxy year in the same position of the 400-year Gregorian
    /// cycle (146 097 days; the calendar repeats exactly), then shift back by
    /// whole cycles. The shift is a fixed number of days, so the UTC offset,
    /// leap days and month lengths all come out exactly as for the real year.
    fn parse_expanded_year(s: &str) -> Result<Self, ParseError> {
        const DAYS_PER_400_YEARS: i64 = 146_097;
        const MAX_YEAR: i64 = 9999; // the `time` crate's default range
        let bad_year = || ParseError(ParseErrorKind::Year);

        let (negative, rest) = (s.starts_with('-'), &s[1..]);
        let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
        // ISO 8601 expanded years have at least four digits; the cap keeps
        // the value inside i64 before the range check.
        if !(4..=18).contains(&digits) {
            return Err(bad_year());
        }
        let magnitude: i64 = rest[..digits].parse().map_err(|_| bad_year())?;
        let year = if negative { -magnitude } else { magnitude };
        if year.abs() > MAX_YEAR {
            return Err(ParseError(ParseErrorKind::OutOfRange));
        }
        let proxy = 2000 + year.rem_euclid(400);
        let cycles = (year - proxy) / 400; // exact: year ≡ proxy (mod 400)
        let base = Self::parse_four_digit_year(&format!("{proxy:04}{}", &rest[digits..]))?;
        base.checked_add(TimeDelta::days(cycles * DAYS_PER_400_YEARS))
            .ok_or(ParseError(ParseErrorKind::OutOfRange))
    }

    /// RFC 3339 with a `+00:00` offset, e.g. `2026-11-18T09:30:00.250+00:00`
    /// (chrono's `to_rfc3339()`).
    #[must_use]
    pub fn to_rfc3339(&self) -> String {
        self.iso('T', "+00:00").to_string()
    }

    /// `self + delta`, or `None` on overflow.
    #[must_use]
    pub fn checked_add(self, delta: TimeDelta) -> Option<Self> {
        self.0.checked_add(delta).map(Self)
    }

    /// `self - delta`, or `None` on overflow.
    #[must_use]
    pub fn checked_sub(self, delta: TimeDelta) -> Option<Self> {
        self.0.checked_sub(delta).map(Self)
    }

    /// The underlying [`time::UtcDateTime`].
    #[must_use]
    pub const fn into_inner(self) -> UtcDateTime {
        self.0
    }

    /// Every text form is this adapter with a different separator and
    /// suffix, so they cannot drift apart.
    const fn iso(&self, sep: char, suffix: &'static str) -> Iso<'_> {
        Iso {
            ts: self,
            sep,
            suffix,
        }
    }
}

/// [`fmt::Display`] adapter for one text form: date, `sep`, time, AutoSi
/// fraction, `suffix`.
struct Iso<'a> {
    ts: &'a Timestamp,
    sep: char,
    suffix: &'static str,
}

impl fmt::Display for Iso<'_> {
    fn fmt(&self, w: &mut fmt::Formatter<'_>) -> fmt::Result {
        let (dt, sep) = (self.ts.0, self.sep);
        let year = dt.year();
        if (0..=9999).contains(&year) {
            write!(w, "{year:04}")?;
        } else {
            write!(w, "{year:+05}")?;
        }
        write!(
            w,
            "-{:02}-{:02}{sep}{:02}:{:02}:{:02}",
            u8::from(dt.month()),
            dt.day(),
            dt.hour(),
            dt.minute(),
            dt.second()
        )?;
        write_fraction(w, dt.nanosecond())?;
        w.write_str(self.suffix)
    }
}

/// chrono's `SecondsFormat::AutoSi`: omit a zero fraction, otherwise use the
/// shortest of 3, 6 or 9 digits that is exact.
fn write_fraction<W: fmt::Write + ?Sized>(w: &mut W, nanos: u32) -> fmt::Result {
    if nanos == 0 {
        Ok(())
    } else if nanos.is_multiple_of(1_000_000) {
        write!(w, ".{:03}", nanos / 1_000_000)
    } else if nanos.is_multiple_of(1_000) {
        write!(w, ".{:06}", nanos / 1_000)
    } else {
        write!(w, ".{nanos:09}")
    }
}

impl Default for Timestamp {
    /// The Unix epoch, as `chrono::DateTime<Utc>::default()` was.
    fn default() -> Self {
        Self::UNIX_EPOCH
    }
}

impl From<UtcDateTime> for Timestamp {
    fn from(dt: UtcDateTime) -> Self {
        Self(dt)
    }
}

impl From<Timestamp> for UtcDateTime {
    fn from(ts: Timestamp) -> Self {
        ts.0
    }
}

impl fmt::Display for Timestamp {
    /// `2026-11-18 09:30:00.250 UTC`, as chrono's `Display` for
    /// `DateTime<Utc>`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self.iso(' ', " UTC"), f)
    }
}

impl fmt::Debug for Timestamp {
    /// `2026-11-18T09:30:00.250Z`, as chrono's `Debug` for `DateTime<Utc>`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self.iso('T', "Z"), f)
    }
}

impl FromStr for Timestamp {
    type Err = ParseError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse_rfc3339(s)
    }
}

impl Serialize for Timestamp {
    /// A string such as `2026-11-18T09:30:00.250Z`, in every serde format
    /// (chrono serialized `DateTime<Utc>` the same way).
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(&self.iso('T', "Z"))
    }
}

impl<'de> Deserialize<'de> for Timestamp {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Visitor;
        impl de::Visitor<'_> for Visitor {
            type Value = Timestamp;

            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("an RFC 3339 formatted date and time string")
            }

            fn visit_str<E: de::Error>(self, v: &str) -> Result<Self::Value, E> {
                Timestamp::parse_rfc3339(v).map_err(E::custom)
            }
        }
        deserializer.deserialize_str(Visitor)
    }
}

impl Add<TimeDelta> for Timestamp {
    type Output = Self;

    /// Panics on overflow, as chrono's `DateTime + TimeDelta` did.
    fn add(self, rhs: TimeDelta) -> Self {
        Self(self.0 + rhs)
    }
}

impl AddAssign<TimeDelta> for Timestamp {
    fn add_assign(&mut self, rhs: TimeDelta) {
        *self = *self + rhs;
    }
}

impl Sub<TimeDelta> for Timestamp {
    type Output = Self;

    /// Panics on overflow, as chrono's `DateTime - TimeDelta` did.
    fn sub(self, rhs: TimeDelta) -> Self {
        Self(self.0 - rhs)
    }
}

impl SubAssign<TimeDelta> for Timestamp {
    fn sub_assign(&mut self, rhs: TimeDelta) {
        *self = *self - rhs;
    }
}

impl Sub for Timestamp {
    type Output = TimeDelta;

    /// The signed span `self - rhs` (chrono's `signed_duration_since`).
    fn sub(self, rhs: Self) -> TimeDelta {
        self.0 - rhs.0
    }
}

/// A string that is not an RFC 3339 timestamp in the supported range.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError(ParseErrorKind);

#[derive(Debug, Clone, PartialEq, Eq)]
enum ParseErrorKind {
    /// Rejected by the RFC 3339 grammar.
    Syntax(time::error::Parse),
    /// A signed (expanded) year that is not a sign and 4–18 digits.
    Year,
    /// Well formed, but outside the representable years `-9999..=9999`.
    OutOfRange,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("invalid RFC 3339 timestamp: ")?;
        match &self.0 {
            ParseErrorKind::Syntax(e) => write!(f, "{e}"),
            ParseErrorKind::Year => f.write_str("malformed signed year"),
            ParseErrorKind::OutOfRange => f.write_str("year outside -9999..=9999"),
        }
    }
}

impl std::error::Error for ParseError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match &self.0 {
            ParseErrorKind::Syntax(e) => Some(e),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The derives the workspace relies on (`Copy` for cheap passing, `Ord`
    /// and `Hash` for map keys and sorting, `Send + Sync` across tasks).
    #[test]
    fn implements_workspace_traits() {
        fn check<T: Send + Sync + Copy + Ord + std::hash::Hash + Default + 'static>() {}
        check::<Timestamp>();
    }

    #[test]
    fn epoch_forms() {
        let e = Timestamp::UNIX_EPOCH;
        assert_eq!(format!("{e:?}"), "1970-01-01T00:00:00Z");
        assert_eq!(e.to_rfc3339(), "1970-01-01T00:00:00+00:00");
        assert_eq!(e.to_string(), "1970-01-01 00:00:00 UTC");
        assert_eq!(Timestamp::default(), e);
    }

    fn at_nanos(n: i128) -> Timestamp {
        Timestamp::from_unix_nanos(n).unwrap()
    }

    #[test]
    fn now_reads_the_system_clock() {
        let sys = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        let now = Timestamp::now();
        assert!((now.unix_seconds() - sys).abs() <= 5, "{now:?} vs {sys}");
        assert!(now > Timestamp::UNIX_EPOCH);
    }

    #[test]
    fn unix_accessors_floor_towards_negative_infinity() {
        let t = at_nanos(1_500_000_123);
        assert_eq!(t.unix_seconds(), 1);
        assert_eq!(t.unix_millis(), 1_500);
        assert_eq!(t.unix_nanos(), 1_500_000_123);
        let before = at_nanos(-1);
        assert_eq!(before.unix_seconds(), -1);
        assert_eq!(before.unix_millis(), -1);
        assert_eq!(before.unix_nanos(), -1);
        assert_eq!(at_nanos(-2_000_000_000).unix_seconds(), -2);
    }

    #[test]
    fn constructors_round_trip_and_reject_out_of_range() {
        let s = Timestamp::from_unix_seconds(1_794_994_200).unwrap();
        assert_eq!(s.to_rfc3339(), "2026-11-18T09:30:00+00:00");
        assert_eq!(s.unix_seconds(), 1_794_994_200);
        assert_eq!(
            Timestamp::from_unix_seconds(-1).unwrap().unix_nanos(),
            -1_000_000_000
        );
        assert!(Timestamp::from_unix_seconds(i64::MAX).is_none());
        assert!(Timestamp::from_unix_seconds(i64::MIN).is_none());
        assert_eq!(
            Timestamp::from_unix_millis(-1).unwrap().unix_nanos(),
            -1_000_000
        );
        assert!(Timestamp::from_unix_millis(i64::MAX).is_none());
    }

    #[test]
    fn checked_arithmetic() {
        let t = at_nanos(1_000_000_000);
        let half = TimeDelta::milliseconds(500);
        assert_eq!(t.checked_add(half).unwrap().unix_millis(), 1_500);
        assert_eq!(t.checked_sub(half).unwrap().unix_millis(), 500);
        assert_eq!(
            t.checked_sub(TimeDelta::seconds(2)).unwrap().unix_seconds(),
            -1
        );
        let max = Timestamp::parse_rfc3339("9999-12-31T23:59:59.999999999Z").unwrap();
        let min = Timestamp::parse_rfc3339("-9999-01-01T00:00:00Z").unwrap();
        assert!(max.checked_add(TimeDelta::nanoseconds(1)).is_none());
        assert!(min.checked_sub(TimeDelta::nanoseconds(1)).is_none());
        assert_eq!(
            min.checked_add(TimeDelta::nanoseconds(1)).unwrap() - min,
            TimeDelta::nanoseconds(1)
        );
    }

    #[test]
    fn compound_assignment() {
        let mut t = at_nanos(0);
        t += TimeDelta::seconds(3);
        assert_eq!(t.unix_seconds(), 3);
        t -= TimeDelta::milliseconds(500);
        assert_eq!(t.unix_millis(), 2_500);
        t -= TimeDelta::seconds(3);
        assert_eq!(t.unix_millis(), -500);
    }

    #[test]
    fn conversions_with_utc_date_time() {
        let dt = UtcDateTime::UNIX_EPOCH + TimeDelta::seconds(90);
        let ts = Timestamp::from(dt);
        assert_eq!(ts.unix_seconds(), 90);
        assert_eq!(ts.into_inner(), dt);
        assert_eq!(UtcDateTime::from(ts), dt);
    }

    #[test]
    fn deserialize_rejects_non_strings_with_the_expected_message() {
        let err = serde_json::from_str::<Timestamp>("1794994200").unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("an RFC 3339 formatted date and time string"),
            "{msg}"
        );
    }

    #[test]
    fn parse_errors_describe_their_cause() {
        use std::error::Error as _;

        let syntax = Timestamp::parse_rfc3339("2026-11-18").unwrap_err();
        assert!(syntax
            .to_string()
            .starts_with("invalid RFC 3339 timestamp: "));
        assert!(syntax.source().is_some());

        let year = Timestamp::parse_rfc3339("-12-01-01T00:00:00Z").unwrap_err();
        assert_eq!(
            year.to_string(),
            "invalid RFC 3339 timestamp: malformed signed year"
        );
        assert!(year.source().is_none());

        let range = Timestamp::parse_rfc3339("+10000-01-01T00:00:00Z").unwrap_err();
        assert_eq!(
            range.to_string(),
            "invalid RFC 3339 timestamp: year outside -9999..=9999"
        );
        assert!(range.source().is_none());
    }
}
