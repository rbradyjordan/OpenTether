//! Vendor-neutral helpers handlers share: the object-handle differ and the
//! standard-property / capture-destination descriptor helpers.

use std::collections::HashSet;
use std::sync::Mutex;

use tether_types::CaptureDestination;

use super::property::{PropertyChoice, PropertyDescriptor, PropertyForm, TetherProperty};
use super::vendor_handler::{CameraEvent, GenericPtpHandler, NewObject, PropertyFormatter};
use crate::ptp::transport::lock;
use crate::ptp::{DevicePropCode, PtpDeviceInfo, PtpEngine, PtpResult, PtpValue};

/// Finds new objects by diffing `GetObjectHandles` against the previous
/// poll. The fallback event source for every vendor whose own event stream
/// is unknown or unreliable (Fujifilm, Olympus, Panasonic, Leica), and a
/// safety net for the others.
///
/// The first call seeds the known set and reports nothing, so objects that
/// were already on the card when we connected are not announced.
pub struct ObjectHandleDiffer {
    known: Mutex<Option<HashSet<u32>>>,
    pub storage: u32,
}

impl Default for ObjectHandleDiffer {
    fn default() -> Self {
        Self::new(0xFFFF_FFFF)
    }
}

impl ObjectHandleDiffer {
    pub fn new(storage: u32) -> Self {
        Self {
            known: Mutex::new(None),
            storage,
        }
    }

    /// Handles present in `current` that were not seen before (ordered as given).
    pub fn diff(&self, current: &[u32]) -> Vec<u32> {
        let mut known = lock(&self.known);
        let fresh = match known.as_ref() {
            None => Vec::new(),
            Some(seen) => current
                .iter()
                .copied()
                .filter(|h| !seen.contains(h))
                .collect(),
        };
        *known = Some(current.iter().copied().collect());
        fresh
    }

    pub fn reset(&self) {
        *lock(&self.known) = None;
    }

    /// Records a handle the camera pushed (ObjectAdded) so the next poll
    /// does not announce it again. Before the first poll this does nothing:
    /// seeding lists the card, pushed handle included.
    ///
    /// Rust deviation: the Swift handlers called `diff([h])`, which replaced
    /// the whole known set with `{h}` and made the next poll re-announce
    /// every file on the card.
    pub fn mark_known(&self, handle: u32) {
        if let Some(seen) = lock(&self.known).as_mut() {
            seen.insert(handle);
        }
    }

    pub fn is_seeded(&self) -> bool {
        lock(&self.known).is_some()
    }

    /// Seed from the camera without reporting anything.
    pub async fn seed(&self, engine: &PtpEngine) {
        if let Ok(handles) = engine.get_object_handles(self.storage, None, 0).await {
            self.diff(&handles);
        }
    }

    /// One poll: list handles, diff, emit `ObjectAdded` for the new ones.
    pub async fn poll(&self, engine: &PtpEngine) -> PtpResult<Vec<CameraEvent>> {
        let handles = engine.get_object_handles(self.storage, None, 0).await?;
        Ok(self
            .diff(&handles)
            .into_iter()
            .map(|h| CameraEvent::ObjectAdded(NewObject::new(h)))
            .collect())
    }
}

/// Shared helpers for handlers that use the standard PTP property codes with
/// a vendor-specific override for codes or display strings.
pub mod vendor_props {
    use super::*;

    /// Reads DevicePropDesc for each property that `code` maps and the body
    /// advertises; formats with `format`.
    pub async fn read_standard(
        engine: &PtpEngine,
        info: &PtpDeviceInfo,
        properties: &[TetherProperty],
        code: impl Fn(TetherProperty) -> Option<DevicePropCode> + Send + Sync,
        format: &PropertyFormatter,
    ) -> PtpResult<Vec<PropertyDescriptor>> {
        let mut out = Vec::new();
        for &p in properties {
            let Some(c) = code(p).filter(|c| info.supports_prop(*c)) else {
                continue;
            };
            let desc = engine.get_device_prop_desc(c).await?;
            out.push(GenericPtpHandler::descriptor(p, &desc, Some(format)));
        }
        Ok(out)
    }

    /// Descriptor for a capture destination the handler tracks itself (the
    /// body has no property for it). Raw values: 0 card, 1 host, 2 both.
    pub fn destination_descriptor(
        current: CaptureDestination,
        allowed: &[CaptureDestination],
        writable: bool,
    ) -> PropertyDescriptor {
        let choices = allowed
            .iter()
            .map(|d| PropertyChoice::new(destination_raw(*d), d.display_name()))
            .collect();
        PropertyDescriptor::new(
            TetherProperty::CaptureDestination,
            destination_raw(current),
            current.display_name(),
            writable,
            PropertyForm::Choices(choices),
        )
    }

    pub fn destination_raw(d: CaptureDestination) -> PtpValue {
        match d {
            CaptureDestination::Card => PtpValue::UInt8(0),
            CaptureDestination::Host => PtpValue::UInt8(1),
            CaptureDestination::Both => PtpValue::UInt8(2),
        }
    }

    pub fn destination_from_raw(v: &PtpValue) -> Option<CaptureDestination> {
        match v.int_value() {
            Some(0) => Some(CaptureDestination::Card),
            Some(1) => Some(CaptureDestination::Host),
            Some(2) => Some(CaptureDestination::Both),
            _ => None,
        }
    }

    /// Choices for a plain lookup table (code → label), sorted by code.
    pub fn choices<K: Ord + Copy>(
        table: &[(K, &str)],
        make: impl Fn(K) -> PtpValue,
    ) -> Vec<PropertyChoice> {
        let mut rows: Vec<(K, &str)> = table.to_vec();
        rows.sort_by_key(|r| r.0);
        rows.into_iter()
            .map(|(k, label)| PropertyChoice::new(make(k), label))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::vendor_props::*;
    use super::*;

    #[test]
    fn differ_seeds_then_reports_new_handles_in_order() {
        let d = ObjectHandleDiffer::default();
        assert!(!d.is_seeded());
        assert!(d.diff(&[1, 2]).is_empty());
        assert!(d.is_seeded());
        assert_eq!(d.diff(&[1, 2, 5, 3]), vec![5, 3]);
        assert!(d.diff(&[1, 2, 5, 3]).is_empty());
        d.reset();
        assert!(d.diff(&[9]).is_empty());
        d.mark_known(10);
        assert!(d.diff(&[9, 10, 11]) == vec![11]);
        let fresh = ObjectHandleDiffer::default();
        fresh.mark_known(1);
        assert!(!fresh.is_seeded());
    }

    #[test]
    fn destination_helpers() {
        let desc = destination_descriptor(
            CaptureDestination::Host,
            &[CaptureDestination::Card, CaptureDestination::Host],
            true,
        );
        assert_eq!(desc.current_choice_index(), Some(1));
        assert_eq!(
            destination_from_raw(&PtpValue::UInt8(2)),
            Some(CaptureDestination::Both)
        );
        let c = choices(&[(3u16, "c"), (1, "a")], PtpValue::UInt16);
        assert_eq!(c[0].display, "a");
    }
}
