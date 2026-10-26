//! Serde helpers that reproduce what Swift's default `JSONEncoder` writes, so
//! the JSON stored in the database (and in settings) is read by both apps.
//!
//! - `Date` → a number of seconds since 2001-01-01T00:00:00Z.
//! - `Data` → a base64 string.
//! - A dictionary whose key is a `String`-backed enum (not `CodingKeyRepresentable`)
//!   → a flat array alternating key and value.
//! - Enums with associated values → `{"case":{...}}`, with unnamed
//!   payloads keyed `_0`, `_1` (handled with mirror enums where used).

use chrono::{DateTime, TimeZone, Utc};

/// Seconds between 1970-01-01 and Swift's reference date, 2001-01-01.
pub const REFERENCE_EPOCH: f64 = 978_307_200.0;

/// Database columns store `timeIntervalSince1970`.
pub fn unix_seconds(d: &DateTime<Utc>) -> f64 {
    d.timestamp() as f64 + f64::from(d.timestamp_subsec_nanos()) / 1e9
}

pub fn from_unix_seconds(s: f64) -> DateTime<Utc> {
    let secs = s.floor();
    let nanos = ((s - secs) * 1e9).round().clamp(0.0, 999_999_999.0) as u32;
    Utc.timestamp_opt(secs as i64, nanos)
        .single()
        .unwrap_or_else(|| DateTime::<Utc>::from_timestamp(0, 0).unwrap_or_default())
}

pub fn reference_seconds(d: &DateTime<Utc>) -> f64 {
    unix_seconds(d) - REFERENCE_EPOCH
}

pub fn from_reference_seconds(s: f64) -> DateTime<Utc> {
    from_unix_seconds(s + REFERENCE_EPOCH)
}

/// A Swift `Date` (seconds since 2001).
pub mod date {
    use super::*;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(d: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_f64(reference_seconds(d))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        Ok(from_reference_seconds(f64::deserialize(d)?))
    }
}

/// A Swift `Date?` (absent key when nil; use with `skip_serializing_if` and `default`).
pub mod opt_date {
    use super::*;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(d: &Option<DateTime<Utc>>, s: S) -> Result<S::Ok, S::Error> {
        match d {
            Some(d) => s.serialize_f64(reference_seconds(d)),
            None => s.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<DateTime<Utc>>, D::Error> {
        Ok(Option::<f64>::deserialize(d)?.map(from_reference_seconds))
    }
}

/// `dateEncodingStrategy = .iso8601`: `2026-10-16T09:41:00Z`.
pub mod iso_date {
    use super::*;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn format(d: &DateTime<Utc>) -> String {
        d.format("%Y-%m-%dT%H:%M:%SZ").to_string()
    }

    pub fn serialize<S: Serializer>(d: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&format(d))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let s = String::deserialize(d)?;
        DateTime::parse_from_rfc3339(&s)
            .map(|d| d.with_timezone(&Utc))
            .map_err(serde::de::Error::custom)
    }
}

/// Swift `Data` as base64.
pub mod base64_data {
    use base64::Engine;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(d: &[u8], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&base64::engine::general_purpose::STANDARD.encode(d))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let s = String::deserialize(d)?;
        base64::engine::general_purpose::STANDARD
            .decode(s.as_bytes())
            .map_err(serde::de::Error::custom)
    }
}

/// `[SomeStringEnum: String]` as Swift writes it: `["k1","v1","k2","v2"]`.
/// Reading also accepts a plain object.
pub mod pair_array_map {
    use serde::de::{self, MapAccess, SeqAccess, Visitor};
    use serde::ser::SerializeSeq;
    use serde::{Deserializer, Serializer};
    use std::collections::BTreeMap;
    use std::fmt;

    pub fn serialize<S: Serializer>(m: &BTreeMap<String, String>, s: S) -> Result<S::Ok, S::Error> {
        let mut seq = s.serialize_seq(Some(m.len() * 2))?;
        for (k, v) in m {
            seq.serialize_element(k)?;
            seq.serialize_element(v)?;
        }
        seq.end()
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        d: D,
    ) -> Result<BTreeMap<String, String>, D::Error> {
        struct V;
        impl<'de> Visitor<'de> for V {
            type Value = BTreeMap<String, String>;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("an alternating key/value array or an object")
            }
            fn visit_seq<A: SeqAccess<'de>>(self, mut a: A) -> Result<Self::Value, A::Error> {
                let mut out = BTreeMap::new();
                while let Some(k) = a.next_element::<String>()? {
                    let v = a
                        .next_element::<String>()?
                        .ok_or_else(|| de::Error::custom("odd number of elements"))?;
                    out.insert(k, v);
                }
                Ok(out)
            }
            fn visit_map<A: MapAccess<'de>>(self, mut a: A) -> Result<Self::Value, A::Error> {
                let mut out = BTreeMap::new();
                while let Some((k, v)) = a.next_entry::<String, String>()? {
                    out.insert(k, v);
                }
                Ok(out)
            }
        }
        d.deserialize_any(V)
    }
}

/// Swift's synthesized coding for a case without payload: `{}`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Empty {}

/// Swift's synthesized coding for one unnamed payload: `{"_0": value}`.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Unnamed<T> {
    #[serde(rename = "_0")]
    pub value: T,
}

/// One optional unnamed payload: `{"_0": value}` or `{}` when nil.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct UnnamedOpt<T> {
    #[serde(rename = "_0", default, skip_serializing_if = "Option::is_none")]
    pub value: Option<T>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reference_date_round_trips() {
        let d = from_unix_seconds(1_792_000_000.25);
        assert!((reference_seconds(&d) - (1_792_000_000.25 - REFERENCE_EPOCH)).abs() < 1e-6);
        assert_eq!(from_reference_seconds(reference_seconds(&d)), d);
    }
}
