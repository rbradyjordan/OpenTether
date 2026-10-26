//! PTP 16-bit codes: operations, responses, events, device properties,
//! object formats and data types (PTP 1.1 §5–§13).

use std::fmt;

/// A 16-bit PTP code. Modelled as an open newtype (not a closed enum)
/// because every vendor extends the code space; `Display` resolves known names.
pub trait PtpCode: Copy + Eq + std::hash::Hash + fmt::Display {
    const KIND: &'static str;
    fn raw(self) -> u16;
    fn name(self) -> Option<&'static str>;
    fn hex(self) -> String {
        format!("0x{:04X}", self.raw())
    }
    fn is_vendor(self) -> bool {
        self.raw() & 0x8000 != 0
    }
}

macro_rules! ptp_code {
    (
        $(#[$meta:meta])*
        $name:ident, $kind:literal,
        consts { $($(#[$cm:meta])* $c:ident = $v:literal,)* }
        names { $($nv:literal => $ns:literal,)* }
    ) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Default)]
        pub struct $name(pub u16);

        impl $name {
            $($(#[$cm])* pub const $c: Self = Self($v);)*
        }

        impl PtpCode for $name {
            const KIND: &'static str = $kind;
            fn raw(self) -> u16 { self.0 }
            fn name(self) -> Option<&'static str> {
                match self.0 {
                    $($nv => Some($ns),)*
                    _ => None,
                }
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                match self.name() {
                    Some(n) => f.write_str(n),
                    None => write!(f, "{}(0x{:04X})", $kind, self.0),
                }
            }
        }

        impl From<u16> for $name {
            fn from(v: u16) -> Self { Self(v) }
        }
    };
}

ptp_code! {
    /// Operation codes (PTP 1.1 §10) plus the MTP ones cameras commonly answer.
    OperationCode, "Op",
    consts {
        UNDEFINED = 0x1000,
        GET_DEVICE_INFO = 0x1001,
        OPEN_SESSION = 0x1002,
        CLOSE_SESSION = 0x1003,
        GET_STORAGE_IDS = 0x1004,
        GET_STORAGE_INFO = 0x1005,
        GET_NUM_OBJECTS = 0x1006,
        GET_OBJECT_HANDLES = 0x1007,
        GET_OBJECT_INFO = 0x1008,
        GET_OBJECT = 0x1009,
        GET_THUMB = 0x100A,
        DELETE_OBJECT = 0x100B,
        SEND_OBJECT_INFO = 0x100C,
        SEND_OBJECT = 0x100D,
        INITIATE_CAPTURE = 0x100E,
        FORMAT_STORE = 0x100F,
        RESET_DEVICE = 0x1010,
        SELF_TEST = 0x1011,
        SET_OBJECT_PROTECTION = 0x1012,
        POWER_DOWN = 0x1013,
        GET_DEVICE_PROP_DESC = 0x1014,
        GET_DEVICE_PROP_VALUE = 0x1015,
        SET_DEVICE_PROP_VALUE = 0x1016,
        RESET_DEVICE_PROP_VALUE = 0x1017,
        TERMINATE_OPEN_CAPTURE = 0x1018,
        MOVE_OBJECT = 0x1019,
        COPY_OBJECT = 0x101A,
        GET_PARTIAL_OBJECT = 0x101B,
        INITIATE_OPEN_CAPTURE = 0x101C,
        GET_OBJECT_PROPS_SUPPORTED = 0x9801,
        GET_OBJECT_PROP_DESC = 0x9802,
        GET_OBJECT_PROP_VALUE = 0x9803,
        SET_OBJECT_PROP_VALUE = 0x9804,
        GET_OBJECT_PROP_LIST = 0x9805,
        GET_PARTIAL_OBJECT_64 = 0x95C1,
    }
    names {
        0x1001 => "GetDeviceInfo", 0x1002 => "OpenSession", 0x1003 => "CloseSession",
        0x1004 => "GetStorageIDs", 0x1005 => "GetStorageInfo", 0x1006 => "GetNumObjects",
        0x1007 => "GetObjectHandles", 0x1008 => "GetObjectInfo", 0x1009 => "GetObject",
        0x100A => "GetThumb", 0x100B => "DeleteObject", 0x100C => "SendObjectInfo",
        0x100D => "SendObject", 0x100E => "InitiateCapture", 0x100F => "FormatStore",
        0x1010 => "ResetDevice", 0x1011 => "SelfTest", 0x1012 => "SetObjectProtection",
        0x1013 => "PowerDown", 0x1014 => "GetDevicePropDesc", 0x1015 => "GetDevicePropValue",
        0x1016 => "SetDevicePropValue", 0x1017 => "ResetDevicePropValue",
        0x1018 => "TerminateOpenCapture", 0x1019 => "MoveObject", 0x101A => "CopyObject",
        0x101B => "GetPartialObject", 0x101C => "InitiateOpenCapture",
        0x9801 => "GetObjectPropsSupported", 0x9802 => "GetObjectPropDesc",
        0x9803 => "GetObjectPropValue", 0x9804 => "SetObjectPropValue",
        0x9805 => "GetObjectPropList", 0x95C1 => "GetPartialObject64",
    }
}

ptp_code! {
    /// Response codes (PTP 1.1 §11).
    ResponseCode, "Resp",
    consts {
        UNDEFINED = 0x2000,
        OK = 0x2001,
        GENERAL_ERROR = 0x2002,
        SESSION_NOT_OPEN = 0x2003,
        INVALID_TRANSACTION_ID = 0x2004,
        OPERATION_NOT_SUPPORTED = 0x2005,
        PARAMETER_NOT_SUPPORTED = 0x2006,
        INCOMPLETE_TRANSFER = 0x2007,
        INVALID_STORAGE_ID = 0x2008,
        INVALID_OBJECT_HANDLE = 0x2009,
        DEVICE_PROP_NOT_SUPPORTED = 0x200A,
        INVALID_OBJECT_FORMAT_CODE = 0x200B,
        STORE_FULL = 0x200C,
        OBJECT_WRITE_PROTECTED = 0x200D,
        STORE_READ_ONLY = 0x200E,
        ACCESS_DENIED = 0x200F,
        NO_THUMBNAIL_PRESENT = 0x2010,
        SELF_TEST_FAILED = 0x2011,
        PARTIAL_DELETION = 0x2012,
        STORE_NOT_AVAILABLE = 0x2013,
        SPECIFICATION_BY_FORMAT_UNSUPPORTED = 0x2014,
        NO_VALID_OBJECT_INFO = 0x2015,
        INVALID_CODE_FORMAT = 0x2016,
        UNKNOWN_VENDOR_CODE = 0x2017,
        CAPTURE_ALREADY_TERMINATED = 0x2018,
        DEVICE_BUSY = 0x2019,
        INVALID_PARENT_OBJECT = 0x201A,
        INVALID_DEVICE_PROP_FORMAT = 0x201B,
        INVALID_DEVICE_PROP_VALUE = 0x201C,
        INVALID_PARAMETER = 0x201D,
        SESSION_ALREADY_OPEN = 0x201E,
        TRANSACTION_CANCELLED = 0x201F,
        SPECIFICATION_OF_DESTINATION_UNSUPPORTED = 0x2020,
    }
    names {
        0x2001 => "OK", 0x2002 => "GeneralError", 0x2003 => "SessionNotOpen",
        0x2004 => "InvalidTransactionID", 0x2005 => "OperationNotSupported",
        0x2006 => "ParameterNotSupported", 0x2007 => "IncompleteTransfer",
        0x2008 => "InvalidStorageID", 0x2009 => "InvalidObjectHandle",
        0x200A => "DevicePropNotSupported", 0x200B => "InvalidObjectFormatCode",
        0x200C => "StoreFull", 0x200D => "ObjectWriteProtected", 0x200E => "StoreReadOnly",
        0x200F => "AccessDenied", 0x2010 => "NoThumbnailPresent", 0x2011 => "SelfTestFailed",
        0x2012 => "PartialDeletion", 0x2013 => "StoreNotAvailable",
        0x2014 => "SpecificationByFormatUnsupported", 0x2015 => "NoValidObjectInfo",
        0x2016 => "InvalidCodeFormat", 0x2017 => "UnknownVendorCode",
        0x2018 => "CaptureAlreadyTerminated", 0x2019 => "DeviceBusy",
        0x201A => "InvalidParentObject", 0x201B => "InvalidDevicePropFormat",
        0x201C => "InvalidDevicePropValue", 0x201D => "InvalidParameter",
        0x201E => "SessionAlreadyOpen", 0x201F => "TransactionCancelled",
        0x2020 => "SpecificationOfDestinationUnsupported",
    }
}

impl ResponseCode {
    pub fn is_ok(self) -> bool {
        self == Self::OK
    }
}

ptp_code! {
    /// Event codes (PTP 1.1 §12).
    EventCode, "Event",
    consts {
        UNDEFINED = 0x4000,
        CANCEL_TRANSACTION = 0x4001,
        OBJECT_ADDED = 0x4002,
        OBJECT_REMOVED = 0x4003,
        STORE_ADDED = 0x4004,
        STORE_REMOVED = 0x4005,
        DEVICE_PROP_CHANGED = 0x4006,
        OBJECT_INFO_CHANGED = 0x4007,
        DEVICE_INFO_CHANGED = 0x4008,
        REQUEST_OBJECT_TRANSFER = 0x4009,
        STORE_FULL = 0x400A,
        DEVICE_RESET = 0x400B,
        STORAGE_INFO_CHANGED = 0x400C,
        CAPTURE_COMPLETE = 0x400D,
        UNREPORTED_STATUS = 0x400E,
    }
    names {
        0x4001 => "CancelTransaction", 0x4002 => "ObjectAdded", 0x4003 => "ObjectRemoved",
        0x4004 => "StoreAdded", 0x4005 => "StoreRemoved", 0x4006 => "DevicePropChanged",
        0x4007 => "ObjectInfoChanged", 0x4008 => "DeviceInfoChanged",
        0x4009 => "RequestObjectTransfer", 0x400A => "StoreFull", 0x400B => "DeviceReset",
        0x400C => "StorageInfoChanged", 0x400D => "CaptureComplete", 0x400E => "UnreportedStatus",
    }
}

ptp_code! {
    /// Device property codes (PTP 1.1 §13).
    DevicePropCode, "Prop",
    consts {
        BATTERY_LEVEL = 0x5001,
        FUNCTIONAL_MODE = 0x5002,
        IMAGE_SIZE = 0x5003,
        COMPRESSION_SETTING = 0x5004,
        WHITE_BALANCE = 0x5005,
        RGB_GAIN = 0x5006,
        F_NUMBER = 0x5007,
        FOCAL_LENGTH = 0x5008,
        FOCUS_DISTANCE = 0x5009,
        FOCUS_MODE = 0x500A,
        EXPOSURE_METERING_MODE = 0x500B,
        FLASH_MODE = 0x500C,
        EXPOSURE_TIME = 0x500D,
        EXPOSURE_PROGRAM_MODE = 0x500E,
        EXPOSURE_INDEX = 0x500F,
        EXPOSURE_BIAS_COMPENSATION = 0x5010,
        DATE_TIME = 0x5011,
        CAPTURE_DELAY = 0x5012,
        STILL_CAPTURE_MODE = 0x5013,
        CONTRAST = 0x5014,
        SHARPNESS = 0x5015,
        DIGITAL_ZOOM = 0x5016,
        EFFECT_MODE = 0x5017,
        BURST_NUMBER = 0x5018,
        BURST_INTERVAL = 0x5019,
        TIMELAPSE_NUMBER = 0x501A,
        TIMELAPSE_INTERVAL = 0x501B,
        FOCUS_METERING_MODE = 0x501C,
        UPLOAD_URL = 0x501D,
        ARTIST = 0x501E,
        COPYRIGHT_INFO = 0x501F,
    }
    names {
        0x5001 => "BatteryLevel", 0x5002 => "FunctionalMode", 0x5003 => "ImageSize",
        0x5004 => "CompressionSetting", 0x5005 => "WhiteBalance", 0x5006 => "RGBGain",
        0x5007 => "FNumber", 0x5008 => "FocalLength", 0x5009 => "FocusDistance",
        0x500A => "FocusMode", 0x500B => "ExposureMeteringMode", 0x500C => "FlashMode",
        0x500D => "ExposureTime", 0x500E => "ExposureProgramMode", 0x500F => "ExposureIndex",
        0x5010 => "ExposureBiasCompensation", 0x5011 => "DateTime", 0x5012 => "CaptureDelay",
        0x5013 => "StillCaptureMode", 0x5014 => "Contrast", 0x5015 => "Sharpness",
        0x5016 => "DigitalZoom", 0x5017 => "EffectMode", 0x5018 => "BurstNumber",
        0x5019 => "BurstInterval", 0x501A => "TimelapseNumber", 0x501B => "TimelapseInterval",
        0x501C => "FocusMeteringMode", 0x501D => "UploadURL", 0x501E => "Artist",
        0x501F => "CopyrightInfo",
    }
}

ptp_code! {
    /// Object formats (PTP 1.1 §6). Vendor RAW values are as observed on the
    /// wire (libgphoto2 / PTP sniffs); the ones marked VERIFY should be
    /// confirmed on a real body. The engine never depends on them for
    /// correctness, only for labelling, and falls back to the file extension
    /// in ObjectInfo.filename.
    ObjectFormat, "Format",
    consts {
        UNDEFINED = 0x3000,
        ASSOCIATION = 0x3001,
        SCRIPT = 0x3002,
        TEXT = 0x3004,
        HTML = 0x3005,
        DPOF = 0x3006,
        WAV = 0x3008,
        AVI = 0x300A,
        MPEG = 0x300B,
        UNDEFINED_IMAGE = 0x3800,
        EXIF_JPEG = 0x3801,
        TIFF_EP = 0x3802,
        FLASH_PIX = 0x3803,
        BMP = 0x3804,
        CIFF = 0x3805,
        GIF = 0x3807,
        JFIF = 0x3808,
        PNG = 0x380B,
        TIFF = 0x380D,
        JP2 = 0x380F,
        JPX = 0x3810,
        DNG = 0x3811,
        HEIF = 0x3812,
        MP4 = 0xB982,
        CANON_CRW = 0xB101,
        CANON_CR2 = 0xB103,
        CANON_CR3 = 0xB108,
        /// VERIFY: Nikon reports NEF as 0x3000 on some bodies.
        NIKON_NEF = 0xB002,
        /// Sony's ARW shares Canon's CRW number; the vendor disambiguates.
        SONY_ARW = 0xB101,
        /// VERIFY
        FUJI_RAF = 0xB105,
        /// VERIFY: collides with Nikon; the vendor disambiguates.
        OLYMPUS_ORF = 0xB002,
        /// VERIFY
        PANASONIC_RW2 = 0xB003,
    }
    names {
        0x3000 => "Undefined", 0x3001 => "Association", 0x3002 => "Script", 0x3004 => "Text",
        0x3005 => "HTML", 0x3006 => "DPOF", 0x3008 => "WAV", 0x300A => "AVI", 0x300B => "MPEG",
        0x3800 => "UndefinedImage", 0x3801 => "EXIF/JPEG", 0x3802 => "TIFF/EP",
        0x3803 => "FlashPix", 0x3804 => "BMP", 0x3805 => "CIFF", 0x3807 => "GIF", 0x3808 => "JFIF",
        0x380B => "PNG", 0x380D => "TIFF", 0x380F => "JP2", 0x3810 => "JPX", 0x3811 => "DNG",
        0x3812 => "HEIF", 0xB982 => "MP4",
    }
}

impl ObjectFormat {
    pub fn is_image(self) -> bool {
        (self.0 & 0xF800) == 0x3800 || self.is_vendor_raw()
    }
    pub fn is_vendor_raw(self) -> bool {
        self.0 >= 0xB000 && self.0 < 0xB900
    }
    pub fn is_jpeg(self) -> bool {
        self == Self::EXIF_JPEG || self == Self::JFIF
    }
}

ptp_code! {
    /// Data types (PTP 1.1 §5.3).
    DataType, "Type",
    consts {
        UNDEF = 0x0000,
        INT8 = 0x0001,
        UINT8 = 0x0002,
        INT16 = 0x0003,
        UINT16 = 0x0004,
        INT32 = 0x0005,
        UINT32 = 0x0006,
        INT64 = 0x0007,
        UINT64 = 0x0008,
        INT128 = 0x0009,
        UINT128 = 0x000A,
        AINT8 = 0x4001,
        AUINT8 = 0x4002,
        AINT16 = 0x4003,
        AUINT16 = 0x4004,
        AINT32 = 0x4005,
        AUINT32 = 0x4006,
        AINT64 = 0x4007,
        AUINT64 = 0x4008,
        AINT128 = 0x4009,
        AUINT128 = 0x400A,
        STRING = 0xFFFF,
    }
    names {
        0x0000 => "UNDEF", 0x0001 => "INT8", 0x0002 => "UINT8", 0x0003 => "INT16", 0x0004 => "UINT16",
        0x0005 => "INT32", 0x0006 => "UINT32", 0x0007 => "INT64", 0x0008 => "UINT64",
        0x0009 => "INT128", 0x000A => "UINT128", 0x4001 => "AINT8", 0x4002 => "AUINT8",
        0x4003 => "AINT16", 0x4004 => "AUINT16", 0x4005 => "AINT32", 0x4006 => "AUINT32",
        0x4007 => "AINT64", 0x4008 => "AUINT64", 0x4009 => "AINT128", 0x400A => "AUINT128",
        0xFFFF => "STR",
    }
}

impl DataType {
    pub fn is_array(self) -> bool {
        self.0 & 0x4000 != 0 && self.0 != 0xFFFF
    }
    pub fn scalar(self) -> Self {
        if self.is_array() {
            Self(self.0 & 0x00FF)
        } else {
            self
        }
    }
}

/// Vendor extension IDs reported in DeviceInfo.vendorExtensionID.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u32)]
pub enum VendorExtensionId {
    EastmanKodak = 0x0001,
    SeikoEpson = 0x0002,
    Agilent = 0x0003,
    Polaroid = 0x0004,
    AgfaGevaert = 0x0005,
    Microsoft = 0x0006,
    Equinox = 0x0007,
    ViewQuest = 0x0008,
    StMicro = 0x0009,
    Nikon = 0x000A,
    Canon = 0x000B,
    FotoNation = 0x000C,
    Pentax = 0x000D,
    Fuji = 0x000E,
    Sony = 0x0011,
    Samsung = 0x001A,
    Parrot = 0x001B,
    Panasonic = 0x001C,
    /// VERIFY: OM bodies often report MTP (0x0006) with Olympus ops.
    Olympus = 0x001D,
    /// VERIFY
    Leica = 0x001E,
}

impl VendorExtensionId {
    pub fn from_raw(v: u32) -> Option<Self> {
        use VendorExtensionId::*;
        [
            EastmanKodak,
            SeikoEpson,
            Agilent,
            Polaroid,
            AgfaGevaert,
            Microsoft,
            Equinox,
            ViewQuest,
            StMicro,
            Nikon,
            Canon,
            FotoNation,
            Pentax,
            Fuji,
            Sony,
            Samsung,
            Parrot,
            Panasonic,
            Olympus,
            Leica,
        ]
        .into_iter()
        .find(|e| *e as u32 == v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_and_fallback() {
        assert_eq!(OperationCode::GET_OBJECT.to_string(), "GetObject");
        assert_eq!(OperationCode(0x9128).to_string(), "Op(0x9128)");
        assert_eq!(ResponseCode::ACCESS_DENIED.to_string(), "AccessDenied");
        assert_eq!(EventCode(0xC201).to_string(), "Event(0xC201)");
        assert!(OperationCode(0x9128).is_vendor());
        assert_eq!(OperationCode::GET_OBJECT.hex(), "0x1009");
    }

    #[test]
    fn data_type_arrays() {
        assert!(DataType::AUINT16.is_array());
        assert_eq!(DataType::AUINT16.scalar(), DataType::UINT16);
        assert!(!DataType::STRING.is_array());
    }
}
