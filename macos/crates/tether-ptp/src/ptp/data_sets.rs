//! PTP datasets: DeviceInfo, StorageInfo, ObjectInfo, DevicePropDesc, and
//! the PTP DateTime string format.

use chrono::{DateTime, FixedOffset, Local, NaiveDate, TimeZone, Utc};
use serde::{Deserialize, Serialize};

use super::byte_buffer::ByteBuffer;
use super::codes::{DataType, DevicePropCode, EventCode, ObjectFormat, OperationCode};
use super::transaction::PtpResult;
use super::value::PtpValue;

/// DeviceInfo dataset (PTP 1.1 §5.1.1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PtpDeviceInfo {
    pub standard_version: u16,
    pub vendor_extension_id: u32,
    pub vendor_extension_version: u16,
    pub vendor_extension_desc: String,
    pub functional_mode: u16,
    pub operations_supported: Vec<OperationCode>,
    pub events_supported: Vec<EventCode>,
    pub device_properties_supported: Vec<DevicePropCode>,
    pub capture_formats: Vec<ObjectFormat>,
    pub image_formats: Vec<ObjectFormat>,
    pub manufacturer: String,
    pub model: String,
    pub device_version: String,
    pub serial_number: String,
}

impl Default for PtpDeviceInfo {
    fn default() -> Self {
        Self {
            standard_version: 100,
            vendor_extension_id: 0,
            vendor_extension_version: 100,
            vendor_extension_desc: String::new(),
            functional_mode: 0,
            operations_supported: Vec::new(),
            events_supported: Vec::new(),
            device_properties_supported: Vec::new(),
            capture_formats: Vec::new(),
            image_formats: Vec::new(),
            manufacturer: String::new(),
            model: String::new(),
            device_version: String::new(),
            serial_number: String::new(),
        }
    }
}

impl PtpDeviceInfo {
    pub fn parse(data: &[u8]) -> PtpResult<Self> {
        let mut b = ByteBuffer::from(data);
        Ok(Self {
            standard_version: b.read_u16()?,
            vendor_extension_id: b.read_u32()?,
            vendor_extension_version: b.read_u16()?,
            vendor_extension_desc: b.read_ptp_string()?,
            functional_mode: b.read_u16()?,
            operations_supported: codes(b.read_u16_array()?),
            events_supported: codes(b.read_u16_array()?),
            device_properties_supported: codes(b.read_u16_array()?),
            capture_formats: codes(b.read_u16_array()?),
            image_formats: codes(b.read_u16_array()?),
            manufacturer: b.read_ptp_string()?,
            model: b.read_ptp_string()?,
            device_version: b.read_ptp_string()?,
            serial_number: b.read_ptp_string()?,
        })
    }

    pub fn encoded(&self) -> Vec<u8> {
        let mut b = ByteBuffer::new();
        b.write_u16(self.standard_version);
        b.write_u32(self.vendor_extension_id);
        b.write_u16(self.vendor_extension_version);
        b.write_ptp_string(&self.vendor_extension_desc);
        b.write_u16(self.functional_mode);
        b.write_u16_array(&raws(&self.operations_supported, |c| c.0));
        b.write_u16_array(&raws(&self.events_supported, |c| c.0));
        b.write_u16_array(&raws(&self.device_properties_supported, |c| c.0));
        b.write_u16_array(&raws(&self.capture_formats, |c| c.0));
        b.write_u16_array(&raws(&self.image_formats, |c| c.0));
        b.write_ptp_string(&self.manufacturer);
        b.write_ptp_string(&self.model);
        b.write_ptp_string(&self.device_version);
        b.write_ptp_string(&self.serial_number);
        b.into_bytes()
    }

    pub fn supports_op(&self, op: OperationCode) -> bool {
        self.operations_supported.contains(&op)
    }
    pub fn supports_prop(&self, prop: DevicePropCode) -> bool {
        self.device_properties_supported.contains(&prop)
    }
    pub fn supports_event(&self, ev: EventCode) -> bool {
        self.events_supported.contains(&ev)
    }
    /// Vendor opcode check by raw value.
    pub fn supports_op_raw(&self, raw: u16) -> bool {
        self.supports_op(OperationCode(raw))
    }
    /// Vendor property check by raw value.
    pub fn supports_prop_raw(&self, raw: u16) -> bool {
        self.supports_prop(DevicePropCode(raw))
    }
}

fn codes<T: From<u16>>(v: Vec<u16>) -> Vec<T> {
    v.into_iter().map(T::from).collect()
}

fn raws<T: Copy>(v: &[T], f: impl Fn(T) -> u16) -> Vec<u16> {
    v.iter().copied().map(f).collect()
}

/// StorageInfo dataset (PTP 1.1 §5.2.2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PtpStorageInfo {
    pub storage_type: u16,
    pub filesystem_type: u16,
    pub access_capability: u16,
    pub max_capacity: u64,
    pub free_space_in_bytes: u64,
    pub free_space_in_images: u32,
    pub storage_description: String,
    pub volume_label: String,
}

/// StorageInfo.storageType values.
pub mod storage_type {
    pub const UNDEFINED: u16 = 0;
    pub const FIXED_ROM: u16 = 1;
    pub const REMOVABLE_ROM: u16 = 2;
    pub const FIXED_RAM: u16 = 3;
    pub const REMOVABLE_RAM: u16 = 4;
}

/// StorageInfo.accessCapability values.
pub mod access_capability {
    pub const READ_WRITE: u16 = 0;
    pub const READ_ONLY_NO_DELETE: u16 = 1;
    pub const READ_ONLY_WITH_DELETE: u16 = 2;
}

impl Default for PtpStorageInfo {
    fn default() -> Self {
        Self {
            storage_type: 4,
            filesystem_type: 2,
            access_capability: 0,
            max_capacity: 0,
            free_space_in_bytes: 0,
            free_space_in_images: 0xFFFF_FFFF,
            storage_description: String::new(),
            volume_label: String::new(),
        }
    }
}

impl PtpStorageInfo {
    pub fn parse(data: &[u8]) -> PtpResult<Self> {
        let mut b = ByteBuffer::from(data);
        Ok(Self {
            storage_type: b.read_u16()?,
            filesystem_type: b.read_u16()?,
            access_capability: b.read_u16()?,
            max_capacity: b.read_u64()?,
            free_space_in_bytes: b.read_u64()?,
            free_space_in_images: b.read_u32()?,
            storage_description: b.read_ptp_string()?,
            volume_label: b.read_ptp_string()?,
        })
    }

    pub fn encoded(&self) -> Vec<u8> {
        let mut b = ByteBuffer::new();
        b.write_u16(self.storage_type);
        b.write_u16(self.filesystem_type);
        b.write_u16(self.access_capability);
        b.write_u64(self.max_capacity);
        b.write_u64(self.free_space_in_bytes);
        b.write_u32(self.free_space_in_images);
        b.write_ptp_string(&self.storage_description);
        b.write_ptp_string(&self.volume_label);
        b.into_bytes()
    }

    /// Removable RAM/ROM = a card. Fixed RAM = SDRAM / internal buffer.
    pub fn is_removable_card(&self) -> bool {
        self.storage_type == storage_type::REMOVABLE_ROM
            || self.storage_type == storage_type::REMOVABLE_RAM
    }
}

/// ObjectInfo dataset (PTP 1.1 §5.3.1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PtpObjectInfo {
    pub storage_id: u32,
    pub object_format: ObjectFormat,
    pub protection_status: u16,
    pub object_compressed_size: u32,
    pub thumb_format: ObjectFormat,
    pub thumb_compressed_size: u32,
    pub thumb_pix_width: u32,
    pub thumb_pix_height: u32,
    pub image_pix_width: u32,
    pub image_pix_height: u32,
    pub image_bit_depth: u32,
    pub parent_object: u32,
    pub association_type: u16,
    pub association_desc: u32,
    pub sequence_number: u32,
    pub filename: String,
    pub capture_date: String,
    pub modification_date: String,
    pub keywords: String,
}

impl Default for PtpObjectInfo {
    fn default() -> Self {
        Self {
            storage_id: 0x0001_0001,
            object_format: ObjectFormat::EXIF_JPEG,
            protection_status: 0,
            object_compressed_size: 0,
            thumb_format: ObjectFormat::EXIF_JPEG,
            thumb_compressed_size: 0,
            thumb_pix_width: 0,
            thumb_pix_height: 0,
            image_pix_width: 0,
            image_pix_height: 0,
            image_bit_depth: 0,
            parent_object: 0,
            association_type: 0,
            association_desc: 0,
            sequence_number: 0,
            filename: String::new(),
            capture_date: String::new(),
            modification_date: String::new(),
            keywords: String::new(),
        }
    }
}

impl PtpObjectInfo {
    pub fn parse(data: &[u8]) -> PtpResult<Self> {
        let mut b = ByteBuffer::from(data);
        Ok(Self {
            storage_id: b.read_u32()?,
            object_format: ObjectFormat(b.read_u16()?),
            protection_status: b.read_u16()?,
            object_compressed_size: b.read_u32()?,
            thumb_format: ObjectFormat(b.read_u16()?),
            thumb_compressed_size: b.read_u32()?,
            thumb_pix_width: b.read_u32()?,
            thumb_pix_height: b.read_u32()?,
            image_pix_width: b.read_u32()?,
            image_pix_height: b.read_u32()?,
            image_bit_depth: b.read_u32()?,
            parent_object: b.read_u32()?,
            association_type: b.read_u16()?,
            association_desc: b.read_u32()?,
            sequence_number: b.read_u32()?,
            filename: b.read_ptp_string()?,
            // Trailing strings are optional on some firmware.
            capture_date: b.read_ptp_string().unwrap_or_default(),
            modification_date: b.read_ptp_string().unwrap_or_default(),
            keywords: b.read_ptp_string().unwrap_or_default(),
        })
    }

    pub fn encoded(&self) -> Vec<u8> {
        let mut b = ByteBuffer::new();
        b.write_u32(self.storage_id);
        b.write_u16(self.object_format.0);
        b.write_u16(self.protection_status);
        b.write_u32(self.object_compressed_size);
        b.write_u16(self.thumb_format.0);
        b.write_u32(self.thumb_compressed_size);
        b.write_u32(self.thumb_pix_width);
        b.write_u32(self.thumb_pix_height);
        b.write_u32(self.image_pix_width);
        b.write_u32(self.image_pix_height);
        b.write_u32(self.image_bit_depth);
        b.write_u32(self.parent_object);
        b.write_u16(self.association_type);
        b.write_u32(self.association_desc);
        b.write_u32(self.sequence_number);
        b.write_ptp_string(&self.filename);
        b.write_ptp_string(&self.capture_date);
        b.write_ptp_string(&self.modification_date);
        b.write_ptp_string(&self.keywords);
        b.into_bytes()
    }

    pub fn is_folder(&self) -> bool {
        self.object_format == ObjectFormat::ASSOCIATION
    }

    /// Lowercased extension of `filename`, empty when there is none.
    pub fn file_extension(&self) -> String {
        std::path::Path::new(&self.filename)
            .extension()
            .map(|e| e.to_string_lossy().to_lowercase())
            .unwrap_or_default()
    }

    /// Best-effort classification used by routing (JPEG → Photos, RAW → Files).
    pub fn media_kind(&self) -> MediaKind {
        let ext = self.file_extension();
        let ext = ext.as_str();
        if self.object_format.is_jpeg() {
            return MediaKind::Jpeg;
        }
        if self.object_format == ObjectFormat::HEIF || ext == "heic" || ext == "hif" {
            return MediaKind::Heif;
        }
        if self.object_format == ObjectFormat::DNG || ext == "dng" {
            return MediaKind::Raw;
        }
        if self.object_format.is_vendor_raw() || MediaKind::RAW_EXTENSIONS.contains(&ext) {
            return MediaKind::Raw;
        }
        if ext == "jxl" {
            return MediaKind::JpegXl;
        }
        if ["mp4", "mov", "avi", "mpg"].contains(&ext)
            || self.object_format == ObjectFormat::MP4
            || self.object_format == ObjectFormat::AVI
        {
            return MediaKind::Video;
        }
        if ext == "jpg" || ext == "jpeg" {
            return MediaKind::Jpeg;
        }
        MediaKind::Other
    }

    /// PTP DateTime strings are `YYYYMMDDThhmmss(.s)(Z|±hhmm)`.
    pub fn capture_date_value(&self) -> Option<DateTime<Utc>> {
        PtpDateTime::parse(&self.capture_date)
    }
}

/// What a file is, for routing. Raw values match the iOS app.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum MediaKind {
    #[serde(rename = "jpeg")]
    Jpeg,
    #[serde(rename = "heif")]
    Heif,
    #[serde(rename = "raw")]
    Raw,
    #[serde(rename = "jpegXL")]
    JpegXl,
    #[serde(rename = "video")]
    Video,
    #[serde(rename = "other")]
    Other,
}

impl MediaKind {
    pub const ALL: [MediaKind; 6] = [
        Self::Jpeg,
        Self::Heif,
        Self::Raw,
        Self::JpegXl,
        Self::Video,
        Self::Other,
    ];

    pub const RAW_EXTENSIONS: &'static [&'static str] = &[
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "sr2", "raf", "orf", "rw2", "dng", "3fr", "fff",
        "pef", "x3f", "iiq",
        // Samsung, Leica, Epson, Leaf/Mamiya, Minolta, Kodak, GoPro, Phase One
        "srw", "rwl", "erf", "mos", "mef", "mrw", "kdc", "dcr", "gpr", "cap", "eip",
    ];

    pub fn raw(self) -> &'static str {
        match self {
            Self::Jpeg => "jpeg",
            Self::Heif => "heif",
            Self::Raw => "raw",
            Self::JpegXl => "jpegXL",
            Self::Video => "video",
            Self::Other => "other",
        }
    }

    pub fn is_still(self) -> bool {
        self != Self::Video && self != Self::Other
    }
}

/// The PTP DateTime string format.
pub struct PtpDateTime;

impl PtpDateTime {
    /// Parses `YYYYMMDDThhmmss`, optional `.s` tenth, optional `Z` or `±hhmm`.
    /// Without a zone the string is read in the local time zone, like iOS.
    pub fn parse(s: &str) -> Option<DateTime<Utc>> {
        let chars: Vec<char> = s.chars().collect();
        if chars.len() < 15 {
            return None;
        }
        let num = |a: usize, b: usize| -> Option<i32> {
            chars.get(a..b)?.iter().collect::<String>().parse().ok()
        };
        let (y, mo, d) = (num(0, 4)?, num(4, 6)?, num(6, 8)?);
        if chars[8] != 'T' {
            return None;
        }
        let (h, mi, se) = (num(9, 11)?, num(11, 13)?, num(13, 15)?);
        let naive = NaiveDate::from_ymd_opt(y, mo as u32, d as u32)?
            .and_hms_opt(h as u32, mi as u32, se as u32)?;
        let mut idx = 15;
        if idx < chars.len() && chars[idx] == '.' {
            idx += 2;
        }
        let mut offset: Option<FixedOffset> = None;
        if idx < chars.len() {
            if chars[idx] == 'Z' {
                offset = FixedOffset::east_opt(0);
            } else if (chars[idx] == '+' || chars[idx] == '-') && idx + 4 < chars.len() {
                if let (Some(hh), Some(mm)) = (
                    num(idx + 1, idx + 3),
                    num(idx + 3, (idx + 5).min(chars.len())),
                ) {
                    let sign = if chars[idx] == '-' { -1 } else { 1 };
                    offset = FixedOffset::east_opt(sign * (hh * 3600 + mm * 60));
                }
            }
        }
        match offset {
            Some(o) => o
                .from_local_datetime(&naive)
                .single()
                .map(|d| d.with_timezone(&Utc)),
            None => Local
                .from_local_datetime(&naive)
                .earliest()
                .map(|d| d.with_timezone(&Utc)),
        }
    }

    /// `yyyyMMdd'T'HHmmss` in the given zone.
    pub fn format<Tz: TimeZone>(date: DateTime<Utc>, zone: &Tz) -> String
    where
        Tz::Offset: std::fmt::Display,
    {
        date.with_timezone(zone).format("%Y%m%dT%H%M%S").to_string()
    }

    /// `yyyyMMdd'T'HHmmss` in the local time zone (what cameras expect).
    pub fn format_local(date: DateTime<Utc>) -> String {
        Self::format(date, &Local)
    }
}

/// The allowed-values part of a DevicePropDesc.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PropForm {
    None,
    Range {
        min: PtpValue,
        max: PtpValue,
        step: PtpValue,
    },
    Enumeration(Vec<PtpValue>),
}

/// DevicePropDesc dataset (PTP 1.1 §5.1.2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PtpDevicePropDesc {
    pub code: DevicePropCode,
    pub data_type: DataType,
    pub is_writable: bool,
    pub factory_default: PtpValue,
    pub current: PtpValue,
    pub form: PropForm,
}

impl PtpDevicePropDesc {
    pub fn parse(data: &[u8]) -> PtpResult<Self> {
        let mut b = ByteBuffer::from(data);
        Self::read(&mut b)
    }

    /// Reads one descriptor from the cursor (vendors pack several in a row).
    pub fn read(b: &mut ByteBuffer) -> PtpResult<Self> {
        let code = DevicePropCode(b.read_u16()?);
        let data_type = DataType(b.read_u16()?);
        let is_writable = b.read_u8()? == 1;
        let factory_default = PtpValue::read(data_type, b)?;
        let current = PtpValue::read(data_type, b)?;
        let form = match b.read_u8()? {
            1 => {
                let min = PtpValue::read(data_type, b)?;
                let max = PtpValue::read(data_type, b)?;
                let step = PtpValue::read(data_type, b)?;
                PropForm::Range { min, max, step }
            }
            2 => {
                let n = b.read_u16()? as usize;
                let mut vals = Vec::with_capacity(n);
                for _ in 0..n {
                    vals.push(PtpValue::read(data_type, b)?);
                }
                PropForm::Enumeration(vals)
            }
            _ => PropForm::None,
        };
        Ok(Self {
            code,
            data_type,
            is_writable,
            factory_default,
            current,
            form,
        })
    }

    pub fn encoded(&self) -> Vec<u8> {
        let mut b = ByteBuffer::new();
        b.write_u16(self.code.0);
        b.write_u16(self.data_type.0);
        b.write_u8(u8::from(self.is_writable));
        self.factory_default.write(&mut b);
        self.current.write(&mut b);
        match &self.form {
            PropForm::None => b.write_u8(0),
            PropForm::Range { min, max, step } => {
                b.write_u8(1);
                min.write(&mut b);
                max.write(&mut b);
                step.write(&mut b);
            }
            PropForm::Enumeration(vals) => {
                b.write_u8(2);
                b.write_u16(vals.len() as u16);
                for v in vals {
                    v.write(&mut b);
                }
            }
        }
        b.into_bytes()
    }

    pub fn enumeration_values(&self) -> Option<&[PtpValue]> {
        match &self.form {
            PropForm::Enumeration(v) => Some(v),
            _ => None,
        }
    }
}
