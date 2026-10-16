import Foundation
import Observation
import TetherCore

/// Small persisted preferences, backed by the store's `settings` table.
@Observable @MainActor
final class AppSettings {
    static let defaultCloudBaseURL = "http://127.0.0.1:8787"

    private let store: SessionStore

    var cloudBaseURL: String { didSet { store.setSetting(Keys.cloudBaseURL, cloudBaseURL) } }
    var accountID: String? { didSet { store.setSetting(Keys.accountID, accountID) } }
    var ftpUsername: String { didSet { store.setSetting(Keys.ftpUsername, ftpUsername) } }
    var ftpPassword: String { didSet { store.setSetting(Keys.ftpPassword, ftpPassword) } }
    var ftpPort: UInt16 { didSet { store.setSetting(Keys.ftpPort, String(ftpPort)) } }
    var hasOnboarded: Bool { didSet { store.setSetting(Keys.onboarded, hasOnboarded ? "1" : "0") } }
    var deviceID: String

    init(store: SessionStore) {
        self.store = store
        cloudBaseURL = store.setting(Keys.cloudBaseURL) ?? AppSettings.defaultCloudBaseURL
        accountID = store.setting(Keys.accountID)
        ftpUsername = store.setting(Keys.ftpUsername) ?? "tether"
        ftpPassword = store.setting(Keys.ftpPassword) ?? AppSettings.randomPassword()
        ftpPort = UInt16(store.setting(Keys.ftpPort) ?? "") ?? 2121
        hasOnboarded = store.setting(Keys.onboarded) == "1"
        if let existing = store.setting(Keys.deviceID) {
            deviceID = existing
        } else {
            deviceID = UUID().uuidString
            store.setSetting(Keys.deviceID, deviceID)
        }
        if store.setting(Keys.ftpPassword) == nil { store.setSetting(Keys.ftpPassword, ftpPassword) }
    }

    var cloudURL: URL { URL(string: cloudBaseURL) ?? URL(string: AppSettings.defaultCloudBaseURL)! }

    /// Read before the settings object exists (the services need the URL first).
    nonisolated static func storedCloudURL(in store: SessionStore) -> URL {
        URL(string: store.setting(Keys.cloudBaseURL) ?? "") ?? URL(string: defaultCloudBaseURL)!
    }

    static func randomPassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0 ..< 8).map { _ in alphabet[Int.random(in: 0 ..< alphabet.count)] })
    }

    private enum Keys {
        static let cloudBaseURL = "cloud.baseURL"
        static let accountID = "cloud.accountID"
        static let ftpUsername = "ftp.username"
        static let ftpPassword = "ftp.password"
        static let ftpPort = "ftp.port"
        static let onboarded = "onboarding.done"
        static let deviceID = "device.id"
    }
}
