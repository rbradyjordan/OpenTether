//! Abstract camera settings, their descriptors and shared display formatters.

use serde::{Deserialize, Serialize};

use crate::ptp::PtpValue;

/// Abstract camera settings. Vendor handlers map these to their own PTP
/// property codes and format raw values for display. Serialised names match
/// the iOS raw values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TetherProperty {
    Aperture,
    ShutterSpeed,
    Iso,
    ExposureCompensation,
    WhiteBalance,
    ColorTemperature,
    ExposureProgram,
    DriveMode,
    MeteringMode,
    FocusMode,
    ImageQuality,
    ImageSize,
    CaptureDestination,
    BatteryLevel,
    LiveViewEnabled,
    FlashMode,
    PictureStyle,
    StorageFreeImages,
    LensName,
    ShutterCount,
}

impl TetherProperty {
    pub const ALL: [TetherProperty; 20] = [
        Self::Aperture,
        Self::ShutterSpeed,
        Self::Iso,
        Self::ExposureCompensation,
        Self::WhiteBalance,
        Self::ColorTemperature,
        Self::ExposureProgram,
        Self::DriveMode,
        Self::MeteringMode,
        Self::FocusMode,
        Self::ImageQuality,
        Self::ImageSize,
        Self::CaptureDestination,
        Self::BatteryLevel,
        Self::LiveViewEnabled,
        Self::FlashMode,
        Self::PictureStyle,
        Self::StorageFreeImages,
        Self::LensName,
        Self::ShutterCount,
    ];

    /// The settings bar on the shoot screen shows these, in this order.
    pub const EXPOSURE_BAR: [TetherProperty; 5] = [
        Self::ShutterSpeed,
        Self::Aperture,
        Self::Iso,
        Self::ExposureCompensation,
        Self::WhiteBalance,
    ];

    /// The iOS raw value (also the serde name).
    pub fn raw(self) -> &'static str {
        match self {
            Self::Aperture => "aperture",
            Self::ShutterSpeed => "shutterSpeed",
            Self::Iso => "iso",
            Self::ExposureCompensation => "exposureCompensation",
            Self::WhiteBalance => "whiteBalance",
            Self::ColorTemperature => "colorTemperature",
            Self::ExposureProgram => "exposureProgram",
            Self::DriveMode => "driveMode",
            Self::MeteringMode => "meteringMode",
            Self::FocusMode => "focusMode",
            Self::ImageQuality => "imageQuality",
            Self::ImageSize => "imageSize",
            Self::CaptureDestination => "captureDestination",
            Self::BatteryLevel => "batteryLevel",
            Self::LiveViewEnabled => "liveViewEnabled",
            Self::FlashMode => "flashMode",
            Self::PictureStyle => "pictureStyle",
            Self::StorageFreeImages => "storageFreeImages",
            Self::LensName => "lensName",
            Self::ShutterCount => "shutterCount",
        }
    }

    pub fn from_raw(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|p| p.raw() == s)
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Aperture => "Aperture",
            Self::ShutterSpeed => "Shutter",
            Self::Iso => "ISO",
            Self::ExposureCompensation => "Exp. comp.",
            Self::WhiteBalance => "White balance",
            Self::ColorTemperature => "Color temp.",
            Self::ExposureProgram => "Mode",
            Self::DriveMode => "Drive",
            Self::MeteringMode => "Metering",
            Self::FocusMode => "Focus",
            Self::ImageQuality => "Quality",
            Self::ImageSize => "Size",
            Self::CaptureDestination => "Destination",
            Self::BatteryLevel => "Battery",
            Self::LiveViewEnabled => "Live view",
            Self::FlashMode => "Flash",
            Self::PictureStyle => "Picture style",
            Self::StorageFreeImages => "Shots left",
            Self::LensName => "Lens",
            Self::ShutterCount => "Shutter count",
        }
    }
}

/// One allowed value of a property.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PropertyChoice {
    pub raw: PtpValue,
    pub display: String,
}

impl PropertyChoice {
    pub fn new(raw: PtpValue, display: impl Into<String>) -> Self {
        Self {
            raw,
            display: display.into(),
        }
    }
}

/// What values a property accepts.
#[derive(Debug, Clone, PartialEq)]
pub enum PropertyForm {
    /// Pick one of the listed choices.
    Choices(Vec<PropertyChoice>),
    /// Numeric range.
    Range { min: f64, max: f64, step: f64 },
    /// Read-only or free-form.
    Other,
}

/// A readable (and maybe writable) property with its allowed values.
#[derive(Debug, Clone, PartialEq)]
pub struct PropertyDescriptor {
    pub property: TetherProperty,
    pub raw: PtpValue,
    pub display: String,
    pub is_writable: bool,
    pub form: PropertyForm,
}

impl PropertyDescriptor {
    pub fn new(
        property: TetherProperty,
        raw: PtpValue,
        display: impl Into<String>,
        is_writable: bool,
        form: PropertyForm,
    ) -> Self {
        Self {
            property,
            raw,
            display: display.into(),
            is_writable,
            form,
        }
    }

    pub fn id(&self) -> TetherProperty {
        self.property
    }

    pub fn choices(&self) -> &[PropertyChoice] {
        match &self.form {
            PropertyForm::Choices(c) => c,
            _ => &[],
        }
    }

    pub fn current_choice_index(&self) -> Option<usize> {
        self.choices().iter().position(|c| c.raw == self.raw)
    }
}

/// Shared formatters for the values every vendor encodes similarly.
pub mod format {
    /// PTP FNumber is f-stop × 100.
    pub fn aperture(hundredths: i64) -> String {
        let f = hundredths as f64 / 100.0;
        if f == f.round() {
            format!("ƒ/{f:.0}")
        } else {
            format!("ƒ/{f:.1}")
        }
    }

    /// PTP ExposureTime is seconds × 10 000.
    pub fn shutter_ten_thousandths(v: i64) -> String {
        shutter_seconds(v as f64 / 10_000.0)
    }

    pub fn shutter_seconds(s: f64) -> String {
        if s <= 0.0 {
            return "Bulb".into();
        }
        if s >= 0.3 {
            return if s == s.round() {
                format!("{s:.0}\"")
            } else {
                format!("{s:.1}\"")
            };
        }
        let denom = (1.0 / s).round();
        format!("1/{}", denom as i64)
    }

    /// Fraction given as numerator/denominator (Nikon, Sony encode this way).
    pub fn shutter_fraction(numerator: i64, denominator: i64) -> String {
        if denominator == 0 {
            return "Bulb".into();
        }
        if numerator >= denominator {
            return shutter_seconds(numerator as f64 / denominator as f64);
        }
        format!("1/{}", denominator / numerator.max(1))
    }

    /// PTP ExposureBiasCompensation is in 1/1000 EV.
    pub fn exposure_compensation(thousandths: i64) -> String {
        let ev = thousandths as f64 / 1000.0;
        if ev == 0.0 {
            return "0".into();
        }
        format!("{ev:+.1}").replace(".0", "")
    }

    pub fn iso(v: i64) -> String {
        if v == 0xFFFF || v == 0xFF_FFFF || v == 0xFFFF_FFFF {
            return "Auto".into();
        }
        v.to_string()
    }

    pub fn white_balance_standard(v: i64) -> String {
        match v {
            1 => "Manual".into(),
            2 => "Auto".into(),
            3 => "One-push auto".into(),
            4 => "Daylight".into(),
            5 => "Fluorescent".into(),
            6 => "Tungsten".into(),
            7 => "Flash".into(),
            _ => format!("WB {v}"),
        }
    }

    pub fn battery(percent: i64) -> String {
        format!("{}%", percent.clamp(0, 100))
    }
}

#[cfg(test)]
mod tests {
    use super::format;
    use super::*;

    #[test]
    fn formatters() {
        assert_eq!(format::aperture(280), "ƒ/2.8");
        assert_eq!(format::aperture(800), "ƒ/8");
        assert_eq!(format::shutter_ten_thousandths(40), "1/250");
        assert_eq!(format::shutter_ten_thousandths(20000), "2\"");
        assert_eq!(format::shutter_ten_thousandths(0), "Bulb");
        assert_eq!(format::shutter_seconds(0.5), "0.5\"");
        assert_eq!(format::shutter_fraction(1, 8000), "1/8000");
        assert_eq!(format::shutter_fraction(25, 10), "2.5\"");
        assert_eq!(format::exposure_compensation(-667), "-0.7");
        assert_eq!(format::exposure_compensation(1000), "+1");
        assert_eq!(format::exposure_compensation(0), "0");
        assert_eq!(format::iso(0xFFFF), "Auto");
        assert_eq!(format::iso(400), "400");
        assert_eq!(format::white_balance_standard(9), "WB 9");
        assert_eq!(format::battery(140), "100%");
    }

    #[test]
    fn property_names_match_ios() {
        assert_eq!(
            serde_json::to_string(&TetherProperty::ExposureCompensation).unwrap(),
            "\"exposureCompensation\""
        );
        for p in TetherProperty::ALL {
            assert_eq!(TetherProperty::from_raw(p.raw()), Some(p));
            assert_eq!(
                serde_json::to_string(&p).unwrap(),
                format!("\"{}\"", p.raw())
            );
        }
    }

    #[test]
    fn descriptor_choice_index() {
        let d = PropertyDescriptor::new(
            TetherProperty::Iso,
            PtpValue::UInt16(400),
            "400",
            true,
            PropertyForm::Choices(vec![
                PropertyChoice::new(PtpValue::UInt16(200), "200"),
                PropertyChoice::new(PtpValue::UInt16(400), "400"),
            ]),
        );
        assert_eq!(d.current_choice_index(), Some(1));
    }
}
