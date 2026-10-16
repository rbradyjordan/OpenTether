import Foundation

/// DeviceInfo dataset (PTP 1.1 §5.1.1).
public struct PTPDeviceInfo: Equatable, Sendable {
    public var standardVersion: UInt16
    public var vendorExtensionID: UInt32
    public var vendorExtensionVersion: UInt16
    public var vendorExtensionDesc: String
    public var functionalMode: UInt16
    public var operationsSupported: [PTPOperationCode]
    public var eventsSupported: [PTPEventCode]
    public var devicePropertiesSupported: [PTPDevicePropCode]
    public var captureFormats: [PTPObjectFormat]
    public var imageFormats: [PTPObjectFormat]
    public var manufacturer: String
    public var model: String
    public var deviceVersion: String
    public var serialNumber: String

    public init(standardVersion: UInt16 = 100, vendorExtensionID: UInt32 = 0, vendorExtensionVersion: UInt16 = 100,
                vendorExtensionDesc: String = "", functionalMode: UInt16 = 0,
                operationsSupported: [PTPOperationCode] = [], eventsSupported: [PTPEventCode] = [],
                devicePropertiesSupported: [PTPDevicePropCode] = [], captureFormats: [PTPObjectFormat] = [],
                imageFormats: [PTPObjectFormat] = [], manufacturer: String = "", model: String = "",
                deviceVersion: String = "", serialNumber: String = "") {
        self.standardVersion = standardVersion
        self.vendorExtensionID = vendorExtensionID
        self.vendorExtensionVersion = vendorExtensionVersion
        self.vendorExtensionDesc = vendorExtensionDesc
        self.functionalMode = functionalMode
        self.operationsSupported = operationsSupported
        self.eventsSupported = eventsSupported
        self.devicePropertiesSupported = devicePropertiesSupported
        self.captureFormats = captureFormats
        self.imageFormats = imageFormats
        self.manufacturer = manufacturer
        self.model = model
        self.deviceVersion = deviceVersion
        self.serialNumber = serialNumber
    }

    public init(parsing data: Data) throws {
        var b = ByteBuffer(data)
        standardVersion = try b.readUInt16()
        vendorExtensionID = try b.readUInt32()
        vendorExtensionVersion = try b.readUInt16()
        vendorExtensionDesc = try b.readPTPString()
        functionalMode = try b.readUInt16()
        operationsSupported = try b.readUInt16Array().map { PTPOperationCode($0) }
        eventsSupported = try b.readUInt16Array().map { PTPEventCode($0) }
        devicePropertiesSupported = try b.readUInt16Array().map { PTPDevicePropCode($0) }
        captureFormats = try b.readUInt16Array().map { PTPObjectFormat($0) }
        imageFormats = try b.readUInt16Array().map { PTPObjectFormat($0) }
        manufacturer = try b.readPTPString()
        model = try b.readPTPString()
        deviceVersion = try b.readPTPString()
        serialNumber = try b.readPTPString()
    }

    public var encoded: Data {
        var b = ByteBuffer()
        b.write(standardVersion)
        b.write(vendorExtensionID)
        b.write(vendorExtensionVersion)
        b.writePTPString(vendorExtensionDesc)
        b.write(functionalMode)
        b.write(uint16Array: operationsSupported.map(\.rawValue))
        b.write(uint16Array: eventsSupported.map(\.rawValue))
        b.write(uint16Array: devicePropertiesSupported.map(\.rawValue))
        b.write(uint16Array: captureFormats.map(\.rawValue))
        b.write(uint16Array: imageFormats.map(\.rawValue))
        b.writePTPString(manufacturer)
        b.writePTPString(model)
        b.writePTPString(deviceVersion)
        b.writePTPString(serialNumber)
        return b.data
    }

    public func supports(_ op: PTPOperationCode) -> Bool { operationsSupported.contains(op) }
    public func supports(_ prop: PTPDevicePropCode) -> Bool { devicePropertiesSupported.contains(prop) }
    public func supports(_ ev: PTPEventCode) -> Bool { eventsSupported.contains(ev) }
}

/// StorageInfo dataset (PTP 1.1 §5.2.2).
public struct PTPStorageInfo: Equatable, Sendable {
    public enum StorageType: UInt16, Sendable { case undefined = 0, fixedROM = 1, removableROM = 2, fixedRAM = 3, removableRAM = 4 }
    public enum AccessCapability: UInt16, Sendable { case readWrite = 0, readOnlyNoDelete = 1, readOnlyWithDelete = 2 }

    public var storageType: UInt16
    public var filesystemType: UInt16
    public var accessCapability: UInt16
    public var maxCapacity: UInt64
    public var freeSpaceInBytes: UInt64
    public var freeSpaceInImages: UInt32
    public var storageDescription: String
    public var volumeLabel: String

    public init(parsing data: Data) throws {
        var b = ByteBuffer(data)
        storageType = try b.readUInt16()
        filesystemType = try b.readUInt16()
        accessCapability = try b.readUInt16()
        maxCapacity = try b.readUInt64()
        freeSpaceInBytes = try b.readUInt64()
        freeSpaceInImages = try b.readUInt32()
        storageDescription = try b.readPTPString()
        volumeLabel = try b.readPTPString()
    }

    public init(storageType: UInt16 = 4, filesystemType: UInt16 = 2, accessCapability: UInt16 = 0,
                maxCapacity: UInt64 = 0, freeSpaceInBytes: UInt64 = 0, freeSpaceInImages: UInt32 = 0xFFFFFFFF,
                storageDescription: String = "", volumeLabel: String = "") {
        self.storageType = storageType; self.filesystemType = filesystemType; self.accessCapability = accessCapability
        self.maxCapacity = maxCapacity; self.freeSpaceInBytes = freeSpaceInBytes; self.freeSpaceInImages = freeSpaceInImages
        self.storageDescription = storageDescription; self.volumeLabel = volumeLabel
    }

    public var encoded: Data {
        var b = ByteBuffer()
        b.write(storageType); b.write(filesystemType); b.write(accessCapability)
        b.write(maxCapacity); b.write(freeSpaceInBytes); b.write(freeSpaceInImages)
        b.writePTPString(storageDescription); b.writePTPString(volumeLabel)
        return b.data
    }

    /// Removable RAM/ROM = a card. Fixed RAM = SDRAM / internal buffer.
    public var isRemovableCard: Bool { storageType == 2 || storageType == 4 }
}

/// ObjectInfo dataset (PTP 1.1 §5.3.1).
public struct PTPObjectInfo: Equatable, Sendable {
    public var storageID: UInt32
    public var objectFormat: PTPObjectFormat
    public var protectionStatus: UInt16
    public var objectCompressedSize: UInt32
    public var thumbFormat: PTPObjectFormat
    public var thumbCompressedSize: UInt32
    public var thumbPixWidth: UInt32
    public var thumbPixHeight: UInt32
    public var imagePixWidth: UInt32
    public var imagePixHeight: UInt32
    public var imageBitDepth: UInt32
    public var parentObject: UInt32
    public var associationType: UInt16
    public var associationDesc: UInt32
    public var sequenceNumber: UInt32
    public var filename: String
    public var captureDate: String
    public var modificationDate: String
    public var keywords: String

    public init(parsing data: Data) throws {
        var b = ByteBuffer(data)
        storageID = try b.readUInt32()
        objectFormat = PTPObjectFormat(try b.readUInt16())
        protectionStatus = try b.readUInt16()
        objectCompressedSize = try b.readUInt32()
        thumbFormat = PTPObjectFormat(try b.readUInt16())
        thumbCompressedSize = try b.readUInt32()
        thumbPixWidth = try b.readUInt32()
        thumbPixHeight = try b.readUInt32()
        imagePixWidth = try b.readUInt32()
        imagePixHeight = try b.readUInt32()
        imageBitDepth = try b.readUInt32()
        parentObject = try b.readUInt32()
        associationType = try b.readUInt16()
        associationDesc = try b.readUInt32()
        sequenceNumber = try b.readUInt32()
        filename = try b.readPTPString()
        captureDate = (try? b.readPTPString()) ?? ""
        modificationDate = (try? b.readPTPString()) ?? ""
        keywords = (try? b.readPTPString()) ?? ""
    }

    public init(storageID: UInt32 = 0x00010001, objectFormat: PTPObjectFormat = .exifJPEG, protectionStatus: UInt16 = 0,
                objectCompressedSize: UInt32 = 0, thumbFormat: PTPObjectFormat = .exifJPEG, thumbCompressedSize: UInt32 = 0,
                thumbPixWidth: UInt32 = 0, thumbPixHeight: UInt32 = 0, imagePixWidth: UInt32 = 0, imagePixHeight: UInt32 = 0,
                imageBitDepth: UInt32 = 0, parentObject: UInt32 = 0, associationType: UInt16 = 0, associationDesc: UInt32 = 0,
                sequenceNumber: UInt32 = 0, filename: String = "", captureDate: String = "", modificationDate: String = "",
                keywords: String = "") {
        self.storageID = storageID; self.objectFormat = objectFormat; self.protectionStatus = protectionStatus
        self.objectCompressedSize = objectCompressedSize; self.thumbFormat = thumbFormat
        self.thumbCompressedSize = thumbCompressedSize; self.thumbPixWidth = thumbPixWidth
        self.thumbPixHeight = thumbPixHeight; self.imagePixWidth = imagePixWidth; self.imagePixHeight = imagePixHeight
        self.imageBitDepth = imageBitDepth; self.parentObject = parentObject; self.associationType = associationType
        self.associationDesc = associationDesc; self.sequenceNumber = sequenceNumber; self.filename = filename
        self.captureDate = captureDate; self.modificationDate = modificationDate; self.keywords = keywords
    }

    public var encoded: Data {
        var b = ByteBuffer()
        b.write(storageID); b.write(objectFormat.rawValue); b.write(protectionStatus); b.write(objectCompressedSize)
        b.write(thumbFormat.rawValue); b.write(thumbCompressedSize); b.write(thumbPixWidth); b.write(thumbPixHeight)
        b.write(imagePixWidth); b.write(imagePixHeight); b.write(imageBitDepth); b.write(parentObject)
        b.write(associationType); b.write(associationDesc); b.write(sequenceNumber)
        b.writePTPString(filename); b.writePTPString(captureDate); b.writePTPString(modificationDate); b.writePTPString(keywords)
        return b.data
    }

    public var isFolder: Bool { objectFormat == .association }
    public var fileExtension: String { (filename as NSString).pathExtension.lowercased() }

    /// Best-effort classification used by routing (JPEG → Photos, RAW → Files).
    public var mediaKind: MediaKind {
        if objectFormat.isJPEG { return .jpeg }
        if objectFormat == .heif || fileExtension == "heic" || fileExtension == "hif" { return .heif }
        if objectFormat == .dng || fileExtension == "dng" { return .raw }
        if objectFormat.isVendorRaw || MediaKind.rawExtensions.contains(fileExtension) { return .raw }
        if fileExtension == "jxl" { return .jpegXL }
        if ["mp4", "mov", "avi", "mpg"].contains(fileExtension) || objectFormat == .mp4 || objectFormat == .avi { return .video }
        if fileExtension == "jpg" || fileExtension == "jpeg" { return .jpeg }
        return .other
    }

    /// PTP DateTime strings are `YYYYMMDDThhmmss(.s)(Z|±hhmm)`.
    public var captureDateValue: Date? { PTPDateTime.parse(captureDate) }
}

public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case jpeg, heif, raw, jpegXL, video, other
    public static let rawExtensions: Set<String> = ["cr2", "cr3", "crw", "nef", "nrw", "arw", "sr2", "raf", "orf", "rw2", "dng", "3fr", "fff", "pef", "x3f", "iiq"]
    public var isStill: Bool { self != .video && self != .other }
}

public enum PTPDateTime {
    /// Parses `YYYYMMDDThhmmss`, optional `.s` tenth, optional `Z` or `±hhmm`.
    public static func parse(_ s: String) -> Date? {
        guard s.count >= 15 else { return nil }
        let chars = Array(s)
        func num(_ r: Range<Int>) -> Int? { Int(String(chars[r])) }
        guard let y = num(0 ..< 4), let mo = num(4 ..< 6), let d = num(6 ..< 8), chars[8] == "T",
              let h = num(9 ..< 11), let mi = num(11 ..< 13), let se = num(13 ..< 15) else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d; comps.hour = h; comps.minute = mi; comps.second = se
        var idx = 15
        if idx < chars.count, chars[idx] == "." { idx += 2 }
        var tz = TimeZone.current
        if idx < chars.count {
            if chars[idx] == "Z" { tz = TimeZone(secondsFromGMT: 0)! }
            else if chars[idx] == "+" || chars[idx] == "-", idx + 4 < chars.count + 0, let hh = num(idx + 1 ..< idx + 3), let mm = num(idx + 3 ..< min(idx + 5, chars.count)) {
                let sign = chars[idx] == "-" ? -1 : 1
                tz = TimeZone(secondsFromGMT: sign * (hh * 3600 + mm * 60)) ?? tz
            }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: comps)
    }

    public static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.string(from: date)
    }
}

/// DevicePropDesc dataset (PTP 1.1 §5.1.2).
public struct PTPDevicePropDesc: Equatable, Sendable {
    public enum Form: Equatable, Sendable {
        case none
        case range(min: PTPValue, max: PTPValue, step: PTPValue)
        case enumeration([PTPValue])
    }

    public var code: PTPDevicePropCode
    public var dataType: PTPDataType
    public var isWritable: Bool
    public var factoryDefault: PTPValue
    public var current: PTPValue
    public var form: Form

    public init(code: PTPDevicePropCode, dataType: PTPDataType, isWritable: Bool, factoryDefault: PTPValue, current: PTPValue, form: Form) {
        self.code = code; self.dataType = dataType; self.isWritable = isWritable
        self.factoryDefault = factoryDefault; self.current = current; self.form = form
    }

    public init(parsing data: Data) throws {
        var b = ByteBuffer(data)
        try self.init(reading: &b)
    }

    public init(reading b: inout ByteBuffer) throws {
        code = PTPDevicePropCode(try b.readUInt16())
        dataType = PTPDataType(try b.readUInt16())
        isWritable = try b.readUInt8() == 1
        factoryDefault = try PTPValue.read(dataType, from: &b)
        current = try PTPValue.read(dataType, from: &b)
        let formFlag = try b.readUInt8()
        switch formFlag {
        case 1:
            let mn = try PTPValue.read(dataType, from: &b)
            let mx = try PTPValue.read(dataType, from: &b)
            let st = try PTPValue.read(dataType, from: &b)
            form = .range(min: mn, max: mx, step: st)
        case 2:
            let n = Int(try b.readUInt16())
            var vals = [PTPValue]()
            for _ in 0 ..< n { vals.append(try PTPValue.read(dataType, from: &b)) }
            form = .enumeration(vals)
        default:
            form = .none
        }
    }

    public var encoded: Data {
        var b = ByteBuffer()
        b.write(code.rawValue); b.write(dataType.rawValue); b.write(UInt8(isWritable ? 1 : 0))
        factoryDefault.write(to: &b); current.write(to: &b)
        switch form {
        case .none: b.write(UInt8(0))
        case .range(let mn, let mx, let st): b.write(UInt8(1)); mn.write(to: &b); mx.write(to: &b); st.write(to: &b)
        case .enumeration(let vals): b.write(UInt8(2)); b.write(UInt16(vals.count)); vals.forEach { $0.write(to: &b) }
        }
        return b.data
    }

    public var enumerationValues: [PTPValue]? {
        if case .enumeration(let v) = form { return v }
        return nil
    }
}
