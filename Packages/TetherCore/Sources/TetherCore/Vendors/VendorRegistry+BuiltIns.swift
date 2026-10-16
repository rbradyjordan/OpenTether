import Foundation

public extension VendorRegistry {
    private static let builtInsLock = NSLock()
    nonisolated(unsafe) private static var builtInsInstalled = false

    /// Registers every PTP vendor handler this package ships. Safe to call
    /// more than once. Ricoh is not registered here: it is reached over
    /// HTTP, not PTP, and is constructed directly (`RicohHandler`).
    static func installBuiltIns() {
        builtInsLock.lock()
        defer { builtInsLock.unlock() }
        if builtInsInstalled { return }
        builtInsInstalled = true
        register(.canon) { engine, info in CanonHandler(engine: engine, info: info) }
        register(.nikon) { engine, info in NikonHandler(engine: engine, info: info) }
        register(.sony) { engine, info in SonyHandler(engine: engine, info: info) }
        register(.fujifilm) { engine, info in FujifilmHandler(engine: engine, info: info) }
        register(.olympus) { engine, info in OlympusHandler(engine: engine, info: info) }
        register(.panasonic) { engine, info in PanasonicHandler(engine: engine, info: info) }
        register(.leica) { engine, info in LeicaHandler(engine: engine, info: info) }
    }

    /// The vendors `installBuiltIns` registers.
    static let builtInVendors: [CameraVendor] = [.canon, .nikon, .sony, .fujifilm, .olympus, .panasonic, .leica]
}
