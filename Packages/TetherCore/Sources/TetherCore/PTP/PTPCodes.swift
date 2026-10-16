import Foundation

/// A 16-bit PTP code. Modelled as an open struct (not a closed enum) because
/// every vendor extends the code space; `description` resolves known names.
public protocol PTPCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible where RawValue == UInt16 {
    static var names: [UInt16: String] { get }
    static var kind: String { get }
}

public extension PTPCode {
    var description: String {
        if let n = Self.names[rawValue] { return n }
        return String(format: "%@(0x%04X)", Self.kind, rawValue)
    }
    var hex: String { String(format: "0x%04X", rawValue) }
    var isVendor: Bool { rawValue & 0x8000 != 0 }
}

// MARK: Operations (PTP 1.1 §10)

public struct PTPOperationCode: PTPCode {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ v: UInt16) { self.rawValue = v }
    public static let kind = "Op"

    public static let undefined = PTPOperationCode(0x1000)
    public static let getDeviceInfo = PTPOperationCode(0x1001)
    public static let openSession = PTPOperationCode(0x1002)
    public static let closeSession = PTPOperationCode(0x1003)
    public static let getStorageIDs = PTPOperationCode(0x1004)
    public static let getStorageInfo = PTPOperationCode(0x1005)
    public static let getNumObjects = PTPOperationCode(0x1006)
    public static let getObjectHandles = PTPOperationCode(0x1007)
    public static let getObjectInfo = PTPOperationCode(0x1008)
    public static let getObject = PTPOperationCode(0x1009)
    public static let getThumb = PTPOperationCode(0x100A)
    public static let deleteObject = PTPOperationCode(0x100B)
    public static let sendObjectInfo = PTPOperationCode(0x100C)
    public static let sendObject = PTPOperationCode(0x100D)
    public static let initiateCapture = PTPOperationCode(0x100E)
    public static let formatStore = PTPOperationCode(0x100F)
    public static let resetDevice = PTPOperationCode(0x1010)
    public static let selfTest = PTPOperationCode(0x1011)
    public static let setObjectProtection = PTPOperationCode(0x1012)
    public static let powerDown = PTPOperationCode(0x1013)
    public static let getDevicePropDesc = PTPOperationCode(0x1014)
    public static let getDevicePropValue = PTPOperationCode(0x1015)
    public static let setDevicePropValue = PTPOperationCode(0x1016)
    public static let resetDevicePropValue = PTPOperationCode(0x1017)
    public static let terminateOpenCapture = PTPOperationCode(0x1018)
    public static let moveObject = PTPOperationCode(0x1019)
    public static let copyObject = PTPOperationCode(0x101A)
    public static let getPartialObject = PTPOperationCode(0x101B)
    public static let initiateOpenCapture = PTPOperationCode(0x101C)
    // MTP extensions commonly answered by cameras
    public static let getObjectPropsSupported = PTPOperationCode(0x9801)
    public static let getObjectPropDesc = PTPOperationCode(0x9802)
    public static let getObjectPropValue = PTPOperationCode(0x9803)
    public static let setObjectPropValue = PTPOperationCode(0x9804)
    public static let getObjectPropList = PTPOperationCode(0x9805)
    public static let getPartialObject64 = PTPOperationCode(0x95C1)

    public static let names: [UInt16: String] = [
        0x1001: "GetDeviceInfo", 0x1002: "OpenSession", 0x1003: "CloseSession",
        0x1004: "GetStorageIDs", 0x1005: "GetStorageInfo", 0x1006: "GetNumObjects",
        0x1007: "GetObjectHandles", 0x1008: "GetObjectInfo", 0x1009: "GetObject",
        0x100A: "GetThumb", 0x100B: "DeleteObject", 0x100C: "SendObjectInfo",
        0x100D: "SendObject", 0x100E: "InitiateCapture", 0x100F: "FormatStore",
        0x1010: "ResetDevice", 0x1011: "SelfTest", 0x1012: "SetObjectProtection",
        0x1013: "PowerDown", 0x1014: "GetDevicePropDesc", 0x1015: "GetDevicePropValue",
        0x1016: "SetDevicePropValue", 0x1017: "ResetDevicePropValue",
        0x1018: "TerminateOpenCapture", 0x1019: "MoveObject", 0x101A: "CopyObject",
        0x101B: "GetPartialObject", 0x101C: "InitiateOpenCapture",
        0x9801: "GetObjectPropsSupported", 0x9802: "GetObjectPropDesc",
        0x9803: "GetObjectPropValue", 0x9804: "SetObjectPropValue",
        0x9805: "GetObjectPropList", 0x95C1: "GetPartialObject64",
    ]
}

// MARK: Responses (PTP 1.1 §11)

public struct PTPResponseCode: PTPCode {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ v: UInt16) { self.rawValue = v }
    public static let kind = "Resp"

    public static let undefined = PTPResponseCode(0x2000)
    public static let ok = PTPResponseCode(0x2001)
    public static let generalError = PTPResponseCode(0x2002)
    public static let sessionNotOpen = PTPResponseCode(0x2003)
    public static let invalidTransactionID = PTPResponseCode(0x2004)
    public static let operationNotSupported = PTPResponseCode(0x2005)
    public static let parameterNotSupported = PTPResponseCode(0x2006)
    public static let incompleteTransfer = PTPResponseCode(0x2007)
    public static let invalidStorageID = PTPResponseCode(0x2008)
    public static let invalidObjectHandle = PTPResponseCode(0x2009)
    public static let devicePropNotSupported = PTPResponseCode(0x200A)
    public static let invalidObjectFormatCode = PTPResponseCode(0x200B)
    public static let storeFull = PTPResponseCode(0x200C)
    public static let objectWriteProtected = PTPResponseCode(0x200D)
    public static let storeReadOnly = PTPResponseCode(0x200E)
    public static let accessDenied = PTPResponseCode(0x200F)
    public static let noThumbnailPresent = PTPResponseCode(0x2010)
    public static let selfTestFailed = PTPResponseCode(0x2011)
    public static let partialDeletion = PTPResponseCode(0x2012)
    public static let storeNotAvailable = PTPResponseCode(0x2013)
    public static let specificationByFormatUnsupported = PTPResponseCode(0x2014)
    public static let noValidObjectInfo = PTPResponseCode(0x2015)
    public static let invalidCodeFormat = PTPResponseCode(0x2016)
    public static let unknownVendorCode = PTPResponseCode(0x2017)
    public static let captureAlreadyTerminated = PTPResponseCode(0x2018)
    public static let deviceBusy = PTPResponseCode(0x2019)
    public static let invalidParentObject = PTPResponseCode(0x201A)
    public static let invalidDevicePropFormat = PTPResponseCode(0x201B)
    public static let invalidDevicePropValue = PTPResponseCode(0x201C)
    public static let invalidParameter = PTPResponseCode(0x201D)
    public static let sessionAlreadyOpen = PTPResponseCode(0x201E)
    public static let transactionCancelled = PTPResponseCode(0x201F)
    public static let specificationOfDestinationUnsupported = PTPResponseCode(0x2020)

    public var isOK: Bool { self == .ok }

    public static let names: [UInt16: String] = [
        0x2001: "OK", 0x2002: "GeneralError", 0x2003: "SessionNotOpen",
        0x2004: "InvalidTransactionID", 0x2005: "OperationNotSupported",
        0x2006: "ParameterNotSupported", 0x2007: "IncompleteTransfer",
        0x2008: "InvalidStorageID", 0x2009: "InvalidObjectHandle",
        0x200A: "DevicePropNotSupported", 0x200B: "InvalidObjectFormatCode",
        0x200C: "StoreFull", 0x200D: "ObjectWriteProtected", 0x200E: "StoreReadOnly",
        0x200F: "AccessDenied", 0x2010: "NoThumbnailPresent", 0x2011: "SelfTestFailed",
        0x2012: "PartialDeletion", 0x2013: "StoreNotAvailable",
        0x2014: "SpecificationByFormatUnsupported", 0x2015: "NoValidObjectInfo",
        0x2016: "InvalidCodeFormat", 0x2017: "UnknownVendorCode",
        0x2018: "CaptureAlreadyTerminated", 0x2019: "DeviceBusy",
        0x201A: "InvalidParentObject", 0x201B: "InvalidDevicePropFormat",
        0x201C: "InvalidDevicePropValue", 0x201D: "InvalidParameter",
        0x201E: "SessionAlreadyOpen", 0x201F: "TransactionCancelled",
        0x2020: "SpecificationOfDestinationUnsupported",
    ]
}

// MARK: Events (PTP 1.1 §12)

public struct PTPEventCode: PTPCode {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ v: UInt16) { self.rawValue = v }
    public static let kind = "Event"

    public static let undefined = PTPEventCode(0x4000)
    public static let cancelTransaction = PTPEventCode(0x4001)
    public static let objectAdded = PTPEventCode(0x4002)
    public static let objectRemoved = PTPEventCode(0x4003)
    public static let storeAdded = PTPEventCode(0x4004)
    public static let storeRemoved = PTPEventCode(0x4005)
    public static let devicePropChanged = PTPEventCode(0x4006)
    public static let objectInfoChanged = PTPEventCode(0x4007)
    public static let deviceInfoChanged = PTPEventCode(0x4008)
    public static let requestObjectTransfer = PTPEventCode(0x4009)
    public static let storeFull = PTPEventCode(0x400A)
    public static let deviceReset = PTPEventCode(0x400B)
    public static let storageInfoChanged = PTPEventCode(0x400C)
    public static let captureComplete = PTPEventCode(0x400D)
    public static let unreportedStatus = PTPEventCode(0x400E)

    public static let names: [UInt16: String] = [
        0x4001: "CancelTransaction", 0x4002: "ObjectAdded", 0x4003: "ObjectRemoved",
        0x4004: "StoreAdded", 0x4005: "StoreRemoved", 0x4006: "DevicePropChanged",
        0x4007: "ObjectInfoChanged", 0x4008: "DeviceInfoChanged",
        0x4009: "RequestObjectTransfer", 0x400A: "StoreFull", 0x400B: "DeviceReset",
        0x400C: "StorageInfoChanged", 0x400D: "CaptureComplete", 0x400E: "UnreportedStatus",
    ]
}

// MARK: Device property codes (PTP 1.1 §13)

public struct PTPDevicePropCode: PTPCode {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ v: UInt16) { self.rawValue = v }
    public static let kind = "Prop"

    public static let batteryLevel = PTPDevicePropCode(0x5001)
    public static let functionalMode = PTPDevicePropCode(0x5002)
    public static let imageSize = PTPDevicePropCode(0x5003)
    public static let compressionSetting = PTPDevicePropCode(0x5004)
    public static let whiteBalance = PTPDevicePropCode(0x5005)
    public static let rgbGain = PTPDevicePropCode(0x5006)
    public static let fNumber = PTPDevicePropCode(0x5007)
    public static let focalLength = PTPDevicePropCode(0x5008)
    public static let focusDistance = PTPDevicePropCode(0x5009)
    public static let focusMode = PTPDevicePropCode(0x500A)
    public static let exposureMeteringMode = PTPDevicePropCode(0x500B)
    public static let flashMode = PTPDevicePropCode(0x500C)
    public static let exposureTime = PTPDevicePropCode(0x500D)
    public static let exposureProgramMode = PTPDevicePropCode(0x500E)
    public static let exposureIndex = PTPDevicePropCode(0x500F)
    public static let exposureBiasCompensation = PTPDevicePropCode(0x5010)
    public static let dateTime = PTPDevicePropCode(0x5011)
    public static let captureDelay = PTPDevicePropCode(0x5012)
    public static let stillCaptureMode = PTPDevicePropCode(0x5013)
    public static let contrast = PTPDevicePropCode(0x5014)
    public static let sharpness = PTPDevicePropCode(0x5015)
    public static let digitalZoom = PTPDevicePropCode(0x5016)
    public static let effectMode = PTPDevicePropCode(0x5017)
    public static let burstNumber = PTPDevicePropCode(0x5018)
    public static let burstInterval = PTPDevicePropCode(0x5019)
    public static let timelapseNumber = PTPDevicePropCode(0x501A)
    public static let timelapseInterval = PTPDevicePropCode(0x501B)
    public static let focusMeteringMode = PTPDevicePropCode(0x501C)
    public static let uploadURL = PTPDevicePropCode(0x501D)
    public static let artist = PTPDevicePropCode(0x501E)
    public static let copyrightInfo = PTPDevicePropCode(0x501F)

    public static let names: [UInt16: String] = [
        0x5001: "BatteryLevel", 0x5002: "FunctionalMode", 0x5003: "ImageSize",
        0x5004: "CompressionSetting", 0x5005: "WhiteBalance", 0x5006: "RGBGain",
        0x5007: "FNumber", 0x5008: "FocalLength", 0x5009: "FocusDistance",
        0x500A: "FocusMode", 0x500B: "ExposureMeteringMode", 0x500C: "FlashMode",
        0x500D: "ExposureTime", 0x500E: "ExposureProgramMode", 0x500F: "ExposureIndex",
        0x5010: "ExposureBiasCompensation", 0x5011: "DateTime", 0x5012: "CaptureDelay",
        0x5013: "StillCaptureMode", 0x5014: "Contrast", 0x5015: "Sharpness",
        0x5016: "DigitalZoom", 0x5017: "EffectMode", 0x5018: "BurstNumber",
        0x5019: "BurstInterval", 0x501A: "TimelapseNumber", 0x501B: "TimelapseInterval",
        0x501C: "FocusMeteringMode", 0x501D: "UploadURL", 0x501E: "Artist",
        0x501F: "CopyrightInfo",
    ]
}

// MARK: Object formats (PTP 1.1 §6)

public struct PTPObjectFormat: PTPCode {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ v: UInt16) { self.rawValue = v }
    public static let kind = "Format"

    public static let undefined = PTPObjectFormat(0x3000)
    public static let association = PTPObjectFormat(0x3001)
    public static let script = PTPObjectFormat(0x3002)
    public static let text = PTPObjectFormat(0x3004)
    public static let html = PTPObjectFormat(0x3005)
    public static let dpof = PTPObjectFormat(0x3006)
    public static let wav = PTPObjectFormat(0x3008)
    public static let avi = PTPObjectFormat(0x300A)
    public static let mpeg = PTPObjectFormat(0x300B)
    public static let undefinedImage = PTPObjectFormat(0x3800)
    public static let exifJPEG = PTPObjectFormat(0x3801)
    public static let tiffEP = PTPObjectFormat(0x3802)
    public static let flashPix = PTPObjectFormat(0x3803)
    public static let bmp = PTPObjectFormat(0x3804)
    public static let ciff = PTPObjectFormat(0x3805)
    public static let gif = PTPObjectFormat(0x3807)
    public static let jfif = PTPObjectFormat(0x3808)
    public static let png = PTPObjectFormat(0x380B)
    public static let tiff = PTPObjectFormat(0x380D)
    public static let jp2 = PTPObjectFormat(0x380F)
    public static let jpx = PTPObjectFormat(0x3810)
    public static let dng = PTPObjectFormat(0x3811)
    public static let heif = PTPObjectFormat(0x3812)
    public static let mp4 = PTPObjectFormat(0xB982)
    // Vendor RAW formats as observed on the wire (libgphoto2 / PTP sniffs).
    // Values marked VERIFY should be confirmed against a real body; the
    // engine never depends on them for correctness, only for labelling, and
    // falls back to the file extension in ObjectInfo.filename.
    public static let canonCRW = PTPObjectFormat(0xB101)
    public static let canonCR2 = PTPObjectFormat(0xB103)
    public static let canonCR3 = PTPObjectFormat(0xB108)
    public static let nikonNEF = PTPObjectFormat(0xB002) // VERIFY: Nikon reports NEF as 0x3000 on some bodies
    public static let sonyARW = PTPObjectFormat(0xB101)  // Sony's ARW shares Canon's CRW number; vendor disambiguates
    public static let fujiRAF = PTPObjectFormat(0xB105)  // VERIFY
    public static let olympusORF = PTPObjectFormat(0xB002) // VERIFY: collides with Nikon; vendor disambiguates
    public static let panasonicRW2 = PTPObjectFormat(0xB003) // VERIFY

    public static let names: [UInt16: String] = [
        0x3000: "Undefined", 0x3001: "Association", 0x3002: "Script", 0x3004: "Text",
        0x3005: "HTML", 0x3006: "DPOF", 0x3008: "WAV", 0x300A: "AVI", 0x300B: "MPEG",
        0x3800: "UndefinedImage", 0x3801: "EXIF/JPEG", 0x3802: "TIFF/EP",
        0x3803: "FlashPix", 0x3804: "BMP", 0x3805: "CIFF", 0x3807: "GIF", 0x3808: "JFIF",
        0x380B: "PNG", 0x380D: "TIFF", 0x380F: "JP2", 0x3810: "JPX", 0x3811: "DNG",
        0x3812: "HEIF", 0xB982: "MP4",
    ]

    public var isImage: Bool { (rawValue & 0xF800) == 0x3800 || isVendorRaw }
    public var isVendorRaw: Bool { rawValue >= 0xB000 && rawValue < 0xB900 }
    public var isJPEG: Bool { self == .exifJPEG || self == .jfif }
}

// MARK: Data types (PTP 1.1 §5.3)

public struct PTPDataType: PTPCode {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ v: UInt16) { self.rawValue = v }
    public static let kind = "Type"

    public static let undef = PTPDataType(0x0000)
    public static let int8 = PTPDataType(0x0001)
    public static let uint8 = PTPDataType(0x0002)
    public static let int16 = PTPDataType(0x0003)
    public static let uint16 = PTPDataType(0x0004)
    public static let int32 = PTPDataType(0x0005)
    public static let uint32 = PTPDataType(0x0006)
    public static let int64 = PTPDataType(0x0007)
    public static let uint64 = PTPDataType(0x0008)
    public static let int128 = PTPDataType(0x0009)
    public static let uint128 = PTPDataType(0x000A)
    public static let aint8 = PTPDataType(0x4001)
    public static let auint8 = PTPDataType(0x4002)
    public static let aint16 = PTPDataType(0x4003)
    public static let auint16 = PTPDataType(0x4004)
    public static let aint32 = PTPDataType(0x4005)
    public static let auint32 = PTPDataType(0x4006)
    public static let aint64 = PTPDataType(0x4007)
    public static let auint64 = PTPDataType(0x4008)
    public static let aint128 = PTPDataType(0x4009)
    public static let auint128 = PTPDataType(0x400A)
    public static let string = PTPDataType(0xFFFF)

    public var isArray: Bool { rawValue & 0x4000 != 0 && rawValue != 0xFFFF }
    public var scalar: PTPDataType { isArray ? PTPDataType(rawValue & 0x00FF) : self }

    public static let names: [UInt16: String] = [
        0x0000: "UNDEF", 0x0001: "INT8", 0x0002: "UINT8", 0x0003: "INT16", 0x0004: "UINT16",
        0x0005: "INT32", 0x0006: "UINT32", 0x0007: "INT64", 0x0008: "UINT64",
        0x0009: "INT128", 0x000A: "UINT128", 0x4001: "AINT8", 0x4002: "AUINT8",
        0x4003: "AINT16", 0x4004: "AUINT16", 0x4005: "AINT32", 0x4006: "AUINT32",
        0x4007: "AINT64", 0x4008: "AUINT64", 0x4009: "AINT128", 0x400A: "AUINT128",
        0xFFFF: "STR",
    ]
}

/// Vendor extension IDs reported in DeviceInfo.vendorExtensionID.
public enum PTPVendorExtensionID: UInt32, Sendable {
    case eastmanKodak = 0x0001
    case seikoEpson = 0x0002
    case agilent = 0x0003
    case polaroid = 0x0004
    case agfaGevaert = 0x0005
    case microsoft = 0x0006
    case equinox = 0x0007
    case viewQuest = 0x0008
    case stMicro = 0x0009
    case nikon = 0x000A
    case canon = 0x000B
    case fotoNation = 0x000C
    case pentax = 0x000D
    case fuji = 0x000E
    case sony = 0x0011
    case samsung = 0x001A
    case parrot = 0x001B
    case panasonic = 0x001C
    case olympus = 0x001D // VERIFY: OM bodies often report MTP (0x0006) with Olympus ops
    case leica = 0x001E   // VERIFY
}
