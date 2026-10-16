import Foundation
import XCTest
@testable import TetherCore

/// DeviceInfo fixtures: one per vendor, listing the operations a real body
/// of that brand advertises, so capabilities derive from runtime flags.
enum VendorFixtures {
    static let standardOps: [PTPOperationCode] = [
        .getDeviceInfo, .openSession, .closeSession, .getStorageIDs, .getStorageInfo, .getObjectHandles,
        .getObjectInfo, .getObject, .getPartialObject, .getThumb, .getDevicePropDesc, .getDevicePropValue, .setDevicePropValue,
    ]
    static let standardProps: [PTPDevicePropCode] = [.fNumber, .exposureTime, .exposureIndex, .exposureBiasCompensation, .whiteBalance, .batteryLevel]

    static func info(_ manufacturer: String, _ model: String, ops: [UInt16], props: [UInt16] = [], extraStandardProps: Bool = true,
                     vendorExtension: UInt32 = 0, serial: String = "SN123") -> PTPDeviceInfo {
        PTPDeviceInfo(vendorExtensionID: vendorExtension,
                      operationsSupported: standardOps + ops.map { PTPOperationCode($0) },
                      eventsSupported: [.objectAdded, .devicePropChanged, .captureComplete],
                      devicePropertiesSupported: (extraStandardProps ? standardProps : []) + props.map { PTPDevicePropCode($0) },
                      captureFormats: [.exifJPEG], imageFormats: [.exifJPEG],
                      manufacturer: manufacturer, model: model, deviceVersion: "1.0", serialNumber: serial)
    }

    static let canon = info("Canon Inc.", "Canon EOS R5", ops: [0x9114, 0x9115, 0x9116, 0x9110, 0x9128, 0x9129, 0x9107, 0x9117, 0x9153, 0x910F],
                            extraStandardProps: false, vendorExtension: 0x0B)
    static let canonOld = info("Canon Inc.", "Canon EOS 5D Mark II", ops: [0x9114, 0x9115, 0x9116, 0x9110, 0x910F, 0x9107, 0x9117],
                               extraStandardProps: false, vendorExtension: 0x0B)
    static let nikonZ = info("Nikon Corporation", "Z 6_2", ops: [0x9038, 0x90C8, 0x90C7, 0x90C0, 0x90CB, 0x9207, 0x9201, 0x9202, 0x9203],
                             props: [0xD100, 0xD1A2, 0xD1A4], vendorExtension: 0x0A)
    static let nikonD = info("Nikon Corporation", "D850", ops: [0x90C2, 0x90C8, 0x90C7, 0x90C0, 0x90CB, 0x9207, 0x9201, 0x9202, 0x9203, 0x100E],
                             props: [0xD100, 0xD1A4], vendorExtension: 0x0A)
    static let sony = PTPDeviceInfo(vendorExtensionID: 0x11,
                                    operationsSupported: standardOps + [0x9201, 0x9202, 0x9205, 0x9207, 0x9209].map { PTPOperationCode($0) },
                                    eventsSupported: [PTPEventCode(0xC201), PTPEventCode(0xC203)],
                                    devicePropertiesSupported: [], captureFormats: [.exifJPEG], imageFormats: [.exifJPEG],
                                    manufacturer: "Sony Corporation", model: "ILCE-7M4", deviceVersion: "2.00", serialNumber: "00001")
    static let sonyMassStorage = info("Sony Corporation", "ILCE-7M4", ops: [], extraStandardProps: false, vendorExtension: 0x11)
    static let fuji = info("FUJIFILM", "X-T5", ops: [0x100E], props: [0xD207, 0xD212, 0xD001, 0xD018], vendorExtension: 0x0E)
    static let olympus = info("OLYMPUS", "E-M1MarkIII", ops: [0x9481, 0x9484], props: [0xD052], vendorExtension: 0x06)
    static let panasonic = info("Panasonic", "DC-S5", ops: [0x9402, 0x9403, 0x9404, 0x9412, 0x9706], extraStandardProps: false, vendorExtension: 0x1C)
    static let leica = info("Leica Camera AG", "SL2", ops: [0x9001, 0x9002, 0x9003, 0x9004, 0x9005, 0x9006], vendorExtension: 0x1E)
}

/// A connected engine + scripted transport for a fixture.
struct VendorRig {
    let transport: ScriptedTransport
    let engine: PTPEngine
    let info: PTPDeviceInfo

    init(_ info: PTPDeviceInfo, kind: TransportKind = .usb) async throws {
        self.info = info
        transport = ScriptedTransport(kind: kind, deviceInfo: info)
        engine = PTPEngine(transport: transport)
        _ = try await engine.connect()
    }

    /// Requests after the connect handshake (GetDeviceInfo, OpenSession).
    var requests: [PTPRequest] { Array(transport.requests.dropFirst(2)) }
    var codes: [PTPOperationCode] { requests.map(\.code) }
}

extension ScriptedTransport {
    func okAll() { onAny { _ in .ok() } }
}

func XCTAssertThrowsPTP<T>(_ expression: @autoclosure () async throws -> T, _ check: (PTPError) -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected a PTPError", file: file, line: line)
    } catch let e as PTPError {
        check(e)
    } catch {
        XCTFail("unexpected error \(error)", file: file, line: line)
    }
}

/// Canned DevicePropDesc for scripted GetDevicePropDesc.
func propDesc(_ code: PTPDevicePropCode, type: PTPDataType, current: Int64, choices: [Int64], writable: Bool = true) -> Data {
    PTPDevicePropDesc(code: code, dataType: type, isWritable: writable, factoryDefault: PTPValue.make(type, current),
                      current: PTPValue.make(type, current), form: .enumeration(choices.map { PTPValue.make(type, $0) })).encoded
}
