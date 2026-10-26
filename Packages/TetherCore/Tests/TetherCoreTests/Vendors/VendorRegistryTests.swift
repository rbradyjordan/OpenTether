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
        XCTAssertFalse(registered.contains(.hasselblad), "generic handler, no dedicated one")
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
        XCTAssertTrue(make(VendorFixtures.info("", "", ops: [0x9114], vendorExtension: 0x0B)) is CanonHandler)
    }

    func testBodiesWithoutVendorModeImportInsteadOfFailing() async throws {
        let t = ScriptedTransport()
        let engine = PTPEngine(transport: t)
        // A PowerShot without EOS remote mode, a Sony not in PC Remote.
        let powershot = VendorRegistry.makeHandler(engine: engine, info: VendorFixtures.info("Canon Inc.", "PowerShot G7 X", ops: [0x1007]), transport: .usb)
        XCTAssertTrue(powershot is GenericPTPHandler)
        XCTAssertTrue(powershot.capabilities.contains(.importOnly))
        let sony = VendorRegistry.makeHandler(engine: engine, info: VendorFixtures.sonyMassStorage, transport: .usb)
        XCTAssertTrue(sony is GenericPTPHandler)
        let events = try await sony.pollEvents()
        XCTAssertTrue(events.contains { if case .warning(let w) = $0 { return w.contains("PC Remote") }; return false }, "hint shown once")
        let again = try await sony.pollEvents()
        XCTAssertFalse(again.contains { if case .warning = $0 { return true }; return false })
    }

    func testNewBrandsAreRecognised() {
        XCTAssertEqual(CameraVendor.detect(VendorFixtures.info("RICOH IMAGING COMPANY, LTD.", "PENTAX K-3 Mark III", ops: [])), .pentax)
        XCTAssertEqual(CameraVendor.detect(VendorFixtures.info("RICOH IMAGING COMPANY, LTD.", "RICOH GR III", ops: [])), .ricoh)
        XCTAssertEqual(CameraVendor.detect(VendorFixtures.info("RICOH", "RICOH THETA Z1", ops: [])), .osc)
        XCTAssertEqual(CameraVendor.detect(VendorFixtures.info("SIGMA", "fp L", ops: [])), .sigma)
        XCTAssertEqual(CameraVendor.detect(VendorFixtures.info("Hasselblad", "X2D 100C", ops: [])), .hasselblad)
        XCTAssertEqual(CameraVendor.detect(VendorFixtures.info("", "", ops: [], vendorExtension: 0x0D)), .pentax)
        XCTAssertEqual(CameraVendor.detect(VendorFixtures.info("", "", ops: [], vendorExtension: 0x1A)), .samsung)
        XCTAssertEqual(CameraVendor.detect(VendorFixtures.info("GoPro", "HERO12 Black", ops: [])), .gopro)
        XCTAssertTrue(CameraVendor.hasselblad.supportsWiredControl, "capability comes from the body, not a block list")
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
