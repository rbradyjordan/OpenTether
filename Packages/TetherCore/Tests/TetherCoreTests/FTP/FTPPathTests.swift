import XCTest
@testable import TetherCore

final class FTPPathTests: XCTestCase {
    func testResolveNormalizes() {
        XCTAssertEqual(FTPPath.resolve("IMG_0001.JPG", cwd: "/"), "/IMG_0001.JPG")
        XCTAssertEqual(FTPPath.resolve("2026/10/16", cwd: "/"), "/2026/10/16")
        XCTAssertEqual(FTPPath.resolve("16", cwd: "/2026/10"), "/2026/10/16")
        XCTAssertEqual(FTPPath.resolve("/abs/./x//y/", cwd: "/ignored"), "/abs/x/y")
        XCTAssertEqual(FTPPath.resolve("..", cwd: "/a/b"), "/a")
        XCTAssertEqual(FTPPath.resolve("../c", cwd: "/a/b"), "/a/c")
        XCTAssertEqual(FTPPath.resolve("", cwd: "/a"), "/a")
        XCTAssertEqual(FTPPath.resolve(".", cwd: "/a"), "/a")
    }

    func testResolveRejectsEscapes() {
        XCTAssertNil(FTPPath.resolve("..", cwd: "/"))
        XCTAssertNil(FTPPath.resolve("../../etc/passwd", cwd: "/a"))
        XCTAssertNil(FTPPath.resolve("/../x", cwd: "/deep/dir"))
        XCTAssertNil(FTPPath.resolve("a/../../..", cwd: "/x"))
        XCTAssertNil(FTPPath.resolve("bad\0name", cwd: "/"))
        XCTAssertNil(FTPPath.resolve("win\\style", cwd: "/"))
    }

    func testParentNameAndURL() {
        XCTAssertEqual(FTPPath.parent(of: "/a/b/c.jpg"), "/a/b")
        XCTAssertEqual(FTPPath.parent(of: "/c.jpg"), "/")
        XCTAssertEqual(FTPPath.parent(of: "/"), "/")
        XCTAssertEqual(FTPPath.name(of: "/a/b/c.jpg"), "c.jpg")
        let root = URL(fileURLWithPath: "/tmp/root")
        XCTAssertEqual(FTPPath.fileURL(root: root, virtual: "/2026/x.jpg").path, "/tmp/root/2026/x.jpg")
        XCTAssertEqual(FTPPath.fileURL(root: root, virtual: "/").path, "/tmp/root")
    }

    func testListingLineRoundTrip() {
        let date = Date(timeIntervalSince1970: 1_760_000_000) // 2025-10-09 UTC
        let file = FTPListing.line(for: .init(name: "IMG 0001.JPG", isDirectory: false, size: 1_048_576, modified: date), now: date)
        XCTAssertTrue(file.hasPrefix("-rw-r--r-- 1 tether tether "))
        XCTAssertTrue(file.contains("1048576 Oct 09 "))
        XCTAssertTrue(file.hasSuffix(" IMG 0001.JPG"))
        let parsed = FTPListing.parse(line: file)
        XCTAssertEqual(parsed?.name, "IMG 0001.JPG")
        XCTAssertEqual(parsed?.size, 1_048_576)
        XCTAssertEqual(parsed?.isDirectory, false)

        let old = FTPListing.line(for: .init(name: "2024", isDirectory: true, size: 4096, modified: date), now: date.addingTimeInterval(400 * 86400))
        XCTAssertTrue(old.hasPrefix("drwxr-xr-x"))
        XCTAssertTrue(old.contains("Oct 09  2025"))
        XCTAssertEqual(FTPListing.parse(line: old)?.isDirectory, true)
        XCTAssertNil(FTPListing.parse(line: "garbage"))
        XCTAssertEqual(FTPListing.mdtmString(date), "20251009085320")
    }

    func testReplyParsers() {
        XCTAssertEqual(FTPReply.parsePASV("Entering Passive Mode (192,168,1,20,156,64)")?.host, "192.168.1.20")
        XCTAssertEqual(FTPReply.parsePASV("Entering Passive Mode (192,168,1,20,156,64)")?.port, 156 << 8 | 64)
        XCTAssertEqual(FTPReply.parsePASV("=10,0,0,1,0,21")?.port, 21)
        XCTAssertNil(FTPReply.parsePASV("Entering Passive Mode (1,2,3)"))
        XCTAssertEqual(FTPReply.parseEPSV("Entering Extended Passive Mode (|||40001|)"), 40001)
        XCTAssertNil(FTPReply.parseEPSV("nope"))
        let r = FTPReply(code: 211, lines: ["Features:", " UTF8", "End"])
        XCTAssertTrue(r.isPositive)
        XCTAssertFalse(FTPReply(code: 150, lines: []).isPositive)
        XCTAssertTrue(FTPReply(code: 150, lines: []).isPreliminary)
    }
}
