import Foundation
import Observation
import TetherCore

/// Small persisted preferences, backed by the store's `settings` table.
@Observable @MainActor
final class AppSettings {
    private let store: SessionStore

    var ftpUsername: String { didSet { store.setSetting(Keys.ftpUsername, ftpUsername) } }
    var ftpPassword: String { didSet { store.setSetting(Keys.ftpPassword, ftpPassword) } }
    var ftpPort: UInt16 { didSet { store.setSetting(Keys.ftpPort, String(ftpPort)) } }
    var hasOnboarded: Bool { didSet { store.setSetting(Keys.onboarded, hasOnboarded ? "1" : "0") } }

    init(store: SessionStore) {
        self.store = store
        ftpUsername = store.setting(Keys.ftpUsername) ?? "tether"
        ftpPassword = store.setting(Keys.ftpPassword) ?? AppSettings.randomPassword()
        ftpPort = UInt16(store.setting(Keys.ftpPort) ?? "") ?? 2121
        hasOnboarded = store.setting(Keys.onboarded) == "1"
        #if DEBUG
        // Simulator screenshots: `simctl launch … -OTSkipOnboarding`.
        if ProcessInfo.processInfo.arguments.contains("-OTSkipOnboarding") { hasOnboarded = true }
        #endif
        if store.setting(Keys.ftpPassword) == nil { store.setSetting(Keys.ftpPassword, ftpPassword) }
    }

    static func randomPassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0 ..< 8).map { _ in alphabet[Int.random(in: 0 ..< alphabet.count)] })
    }

    private enum Keys {
        static let ftpUsername = "ftp.username"
        static let ftpPassword = "ftp.password"
        static let ftpPort = "ftp.port"
        static let onboarded = "onboarding.done"
    }
}
