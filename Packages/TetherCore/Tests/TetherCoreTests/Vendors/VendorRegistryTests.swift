import XCTest
@testable import TetherCore

final class VendorRegistryBuiltInsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        VendorRegistry.installBuiltIns()
        VendorRegistry.installBuiltIns() // idempotent
    }

    func testEveryBuiltInVendorIsRegistered() {
        let registered = Set(VendorRegistry.registered)
        for v in VendorRegistry.builtInVendors { XCTAssertTrue(registered.contains(v), "\(v)") }
        XCTAssertFalse(registered.contains(.ricoh))
        XCTAssertFalse(registered.contains(.hasselblad))
    }

    func testManufacturerStringsResolveToHandlers() {
        let t = ScriptedTransport()
        let engine = PTPEngine(transport: t)
        func make(_ info: PTPDeviceInfo, _ kind: TransportKind = .usb) -> VendorHandler {
            VendorRegistry.makeHandler(engine: engine, info: info, transport: kind)
        }
        XCTAssertTrue(make(VendorFixtures.canon) is CanonHandler)
        XCTAssertTrue(make(VendorFixtures.nikonZ) is NikonHandler)
        XCTAssertTrue(make(VendorFixtures.sony) is SonyHandler)
        XCTAssertTrue(make(VendorFixtures.fuji) is FujifilmHandler)
        XCTAssertTrue(make(VendorFixtures.olympus) is OlympusHandler)
        XCTAssertTrue(make(VendorFixtures.panasonic) is PanasonicHandler)
        XCTAssertTrue(make(VendorFixtures.leica) is LeicaHandler)
        // OM System branding and vendor-extension-only detection still land on the right class.
        XCTAssertTrue(make(VendorFixtures.info("OM Digital Solutions", "OM-1", ops: [0x9481])) is OlympusHandler)
        XCTAssertTrue(make(PTPDeviceInfo(vendorExtensionID: 0x0B, manufacturer: "", model: "")) is CanonHandler)
    }

    func testUnknownHasselbladAndWirelessWiredOnlyFallBackToGeneric() {
        let t = ScriptedTransport()
        let engine = PTPEngine(transport: t)
        XCTAssertTrue(VendorRegistry.makeHandler(engine: engine, info: ScriptedTransport.genericInfo, transport: .usb) is GenericPTPHandler)
        var hb = ScriptedTransport.genericInfo
        hb.manufacturer = "Hasselblad"
        XCTAssertTrue(VendorRegistry.makeHandler(engine: engine, info: hb, transport: .usb) is GenericPTPHandler)
        // Wired-only brands over PTP/IP get the generic importer; wireless-capable brands keep theirs.
        XCTAssertTrue(VendorRegistry.makeHandler(engine: engine, info: VendorFixtures.olympus, transport: .ptpip) is GenericPTPHandler)
        XCTAssertTrue(VendorRegistry.makeHandler(engine: engine, info: VendorFixtures.panasonic, transport: .ptpip) is GenericPTPHandler)
        XCTAssertTrue(VendorRegistry.makeHandler(engine: engine, info: VendorFixtures.leica, transport: .ptpip) is GenericPTPHandler)
        XCTAssertTrue(VendorRegistry.makeHandler(engine: engine, info: VendorFixtures.canon, transport: .ptpip) is CanonHandler)
        XCTAssertTrue(VendorRegistry.makeHandler(engine: engine, info: VendorFixtures.fuji, transport: .ptpip) is FujifilmHandler)
    }
}
