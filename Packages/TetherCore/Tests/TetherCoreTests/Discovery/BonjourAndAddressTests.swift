import XCTest
@testable import TetherCore

final class BonjourAndAddressTests: XCTestCase {
    func testBrandMapper() {
        XCTAssertEqual(BonjourBrandMapper.vendor(forHost: "EOSR5-123456.local.", serviceName: "Canon EOS R5"), .canon)
        XCTAssertEqual(BonjourBrandMapper.vendor(forHost: "abc.nicname.canon.com", serviceName: nil), .canon)
        XCTAssertEqual(BonjourBrandMapper.vendor(forHost: "NIKON-Z6_2.local.", serviceName: "Z 6_2"), .nikon)
        XCTAssertEqual(BonjourBrandMapper.vendor(forHost: nil, serviceName: "ILCE-7M4"), .sony)
        XCTAssertEqual(BonjourBrandMapper.vendor(forHost: "DSC-RX100M7.local.", serviceName: nil), .sony)
        XCTAssertEqual(BonjourBrandMapper.vendor(forHost: nil, serviceName: "X-T5"), .fujifilm)
        XCTAssertEqual(BonjourBrandMapper.vendor(forHost: "GFX100S.local.", serviceName: "FUJIFILM GFX100S"), .fujifilm)
        XCTAssertEqual(BonjourBrandMapper.vendor(forHost: nil, serviceName: "LEICA SL2"), .leica)
        XCTAssertEqual(BonjourBrandMapper.vendor(forHost: "OM-1.local.", serviceName: nil), .olympus)
        XCTAssertEqual(BonjourBrandMapper.vendor(forHost: nil, serviceName: "Olympus E-M1X"), .olympus)
        XCTAssertEqual(BonjourBrandMapper.vendor(forHost: nil, serviceName: "LUMIX S5"), .panasonic)
        XCTAssertEqual(BonjourBrandMapper.vendor(forHost: "panasonic-dc-gh6.local.", serviceName: nil), .panasonic)
        XCTAssertNil(BonjourBrandMapper.vendor(forHost: "printer.local.", serviceName: "HP LaserJet"))
        XCTAssertNil(BonjourBrandMapper.vendor(forHost: nil, serviceName: nil))
    }

    func testIPAddressFilter() {
        XCTAssertTrue(IPAddressFilter.isUsable("192.168.1.20"))
        XCTAssertTrue(IPAddressFilter.isUsable("10.0.0.5"))
        XCTAssertFalse(IPAddressFilter.isUsable("169.254.10.1"))
        XCTAssertFalse(IPAddressFilter.isUsable("127.0.0.1"))
        XCTAssertFalse(IPAddressFilter.isUsable("0.0.0.0"))
        XCTAssertFalse(IPAddressFilter.isUsable("fe80::1c99:4cff:fe1b:4f3a"))
        XCTAssertFalse(IPAddressFilter.isUsable("fe80::1%en0"))
        XCTAssertTrue(IPAddressFilter.isUsable("fd00::2"))
        XCTAssertTrue(IPAddressFilter.isUsable("2001:db8::1"))
        XCTAssertFalse(IPAddressFilter.isUsable("::1"))
        XCTAssertFalse(IPAddressFilter.isUsable("not an address"))
        XCTAssertEqual(IPAddressFilter.preferred(["fe80::1", "fd00::2", "169.254.1.1", "192.168.0.9"]), "192.168.0.9")
        XCTAssertEqual(IPAddressFilter.preferred(["fe80::1", "fd00::2"]), "fd00::2")
        XCTAssertNil(IPAddressFilter.preferred(["fe80::1", "169.254.9.9"]))
    }

    func testBonjourCameraMapping() {
        let cam = BonjourDiscoverer.camera(serviceName: "Canon EOS R6", serviceType: "_ptp._tcp.", hostName: "EOSR6-ABC.local.",
                                           host: "192.168.1.30", port: 15740, txt: ["ty": "Canon EOS R6"])
        XCTAssertEqual(cam.id, "bonjour:Canon EOS R6")
        XCTAssertEqual(cam.vendor, .canon)
        XCTAssertEqual(cam.method, .bonjour)
        XCTAssertEqual(cam.transport, .ptpip)
        XCTAssertEqual(cam.details["serviceType"], "_ptp._tcp.")
        XCTAssertEqual(cam.details["hostname"], "EOSR6-ABC.local.")
        XCTAssertEqual(cam.details["model"], "Canon EOS R6")
        XCTAssertTrue(cam.isControllable)
        // Unknown brand still surfaces (generic PTP/IP) but uncontrollable.
        let unknown = BonjourDiscoverer.camera(serviceName: "Mystery", serviceType: "_ptp._tcp.", hostName: nil, host: "10.0.0.2", port: 15740)
        XCTAssertNil(unknown.vendor)
        XCTAssertFalse(unknown.isControllable)
    }

    func testBonjourStubStartsOnLinux() async throws {
        let b = BonjourDiscoverer()
        try await b.start()
        await b.stop()
        XCTAssertEqual(b.current.count, 0)
    }

    func testInterfacesAndBroadcast() {
        XCTAssertEqual(NetworkInterfaces.broadcastAddress(address: "192.168.1.20", netmask: "255.255.255.0"), "192.168.1.255")
        XCTAssertEqual(NetworkInterfaces.broadcastAddress(address: "10.1.2.3", netmask: "255.255.0.0"), "10.1.255.255")
        XCTAssertNil(NetworkInterfaces.broadcastAddress(address: "bad", netmask: "255.0.0.0"))
        let locals = CameraDiscoverer.localIPv4Addresses()
        XCTAssertFalse(locals.contains("127.0.0.1"))
        XCTAssertTrue(locals.allSatisfy(IPAddressFilter.isUsable))
        let bcasts = CameraDiscoverer.broadcastAddresses()
        XCTAssertTrue(bcasts.contains("255.255.255.255"))
        XCTAssertEqual(Set(bcasts).count, bcasts.count)
        // Loopback is enumerated but flagged.
        XCTAssertTrue(NetworkInterfaces.ipv4Interfaces().contains { $0.isLoopback && $0.address == "127.0.0.1" })
    }
}
