import TetherCore
import XCTest
@testable import Tether

final class ReconnectStrategyTests: XCTestCase {
    func testUSBWaitsForTheSameSerial() {
        XCTAssertEqual(ReconnectStrategy.choose(for: .usb(deviceID: "x", serial: "123")), .waitForUSBDevice(serial: "123"))
    }

    func testPTPIPRetriesHostAndFallsBackWhenUnknown() {
        XCTAssertEqual(ReconnectStrategy.choose(for: .ptpip(host: "192.168.1.5", port: 15740, vendor: .canon)),
                       .retryHost(host: "192.168.1.5", port: 15740, vendor: .canon))
        XCTAssertEqual(ReconnectStrategy.choose(for: .ptpip(host: "", port: 15740, vendor: nil)), .startFresh)
    }

    func testFTPHasNothingToDo() {
        XCTAssertEqual(ReconnectStrategy.choose(for: .ftp), .nothingToDo)
    }

    func testContextFromStoredSession() {
        var s = ShootSession(name: "t")
        s.transport = .ptpip
        s.lastHost = "10.0.0.2"
        XCTAssertEqual(ReconnectContext.from(session: s), .ptpip(host: "10.0.0.2", port: 15740, vendor: nil))
        s.transport = .ricohHTTP
        s.lastHost = nil
        XCTAssertEqual(ReconnectContext.from(session: s), .ricoh(host: "192.168.0.1"))
    }
}
