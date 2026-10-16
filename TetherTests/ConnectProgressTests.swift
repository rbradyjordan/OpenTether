import TetherCore
import XCTest
@testable import Tether

final class ConnectProgressTests: XCTestCase {
    func testAdvanceMarksEarlierStepsDone() {
        var p = ConnectProgress(transport: .ptpip)
        p.advance(to: .session)
        XCTAssertEqual(p.state(of: .link), .done)
        XCTAssertEqual(p.state(of: .initEvent), .done)
        XCTAssertEqual(p.state(of: .session), .running)
        XCTAssertEqual(p.state(of: .deviceInfo), .pending)
        p.fail("boom")
        XCTAssertEqual(p.state(of: .session), .failed)
    }

    func testUSBSkipsHandshakeSteps() {
        XCTAssertFalse(ConnectStep.steps(for: .usb).contains(.initCommand))
        var p = ConnectProgress(transport: .usb)
        p.advance(to: .ready)
        XCTAssertEqual(p.state(of: .ready), .done)
        XCTAssertNil(p.current)
    }
}
