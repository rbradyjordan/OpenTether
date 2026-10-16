// swift-tools-version:5.10
// TetherCore: the transport-agnostic PTP engine, PTP/IP, discovery, FTP,
// capture pipeline, review state, persistence and cloud client for the
// Tether iOS app. Pure Swift + Foundation so the engine builds and tests on
// Linux; Apple-only pieces (ImageCaptureCore, NSStream, Core Image) are
// guarded with `#if canImport(...)`.
import PackageDescription

let package = Package(
    name: "TetherCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TetherCore", targets: ["TetherCore"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]
        ),
        .systemLibrary(
            name: "CCurl",
            path: "Sources/CCurl",
            pkgConfig: "libcurl",
            providers: [.apt(["libcurl4-openssl-dev"]), .brew(["curl"])]
        ),
        .target(
            name: "TetherCore",
            dependencies: [
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
                // libcurl FTP/FTPS client: Linux only here. Apple platforms use
                // StreamFTPClient; iOS would need a prebuilt libcurl xcframework.
                .target(name: "CCurl", condition: .when(platforms: [.linux])),
            ],
            path: "Sources/TetherCore"
        ),
        .testTarget(
            name: "TetherCoreTests",
            dependencies: ["TetherCore"],
            path: "Tests/TetherCoreTests"
        ),
    ]
)
