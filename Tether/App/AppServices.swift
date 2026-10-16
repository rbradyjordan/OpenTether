import Foundation
import TetherCore

/// Wires the core package to the platform adapters. Built once at launch.
struct AppServices {
    let store: SessionStore
    let cache: CaptureCacheProxy
    let keychain: KeychainStore
    let tokens: KeychainTokenStore
    let previews: ImageIOPreviewGenerator
    let renderer: CoreImageLookRenderer
    let lookResolver: LookResolver
    let exportQueue: ExportQueue
    let discovery: CameraDiscoverer
    let ssid: any SSIDProviding
    let usbBrowser: USBCameraBrowser
    let ptpLog: PTPLog
    let ftpInbox: URL
    /// The client the export queue was built with; `AppModel.cloud` may be newer
    /// when the base URL was edited (takes effect for exports after relaunch).
    let cloud: TetherCloudClient

    static func make() throws -> AppServices {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let store = try SessionStore(path: support.appendingPathComponent("tether.sqlite").path)
        let cloudURL = AppSettings.storedCloudURL(in: store)
        let cache = CaptureCacheProxy(storageRoot: support.appendingPathComponent("Captures", isDirectory: true))
        let keychain = KeychainStore()
        let tokens = KeychainTokenStore(keychain: keychain)
        let cloud = TetherCloudClient(baseURL: cloudURL, tokens: tokens)
        let resolver = LookResolver(store: store) { look in try await cloud.cube(look) }
        let renderer = CoreImageLookRenderer()
        let sink = RoutingExportSink(photos: PhotosExportSink(store: store), files: FilesExportSink(store: store))
        let queue = ExportQueue(store: store, cache: cache, sink: sink, renderer: renderer, cloud: cloud, looks: resolver,
                                ftpClientFactory: { dest in AppServices.ftpUploader(for: dest, keychain: keychain) })
        VendorRegistry.installBuiltIns()
        return AppServices(store: store, cache: cache, keychain: keychain, tokens: tokens,
                           previews: ImageIOPreviewGenerator(), renderer: renderer, lookResolver: resolver,
                           exportQueue: queue, discovery: CameraDiscoverer(), ssid: CoreLocationSSIDMonitor(),
                           usbBrowser: USBCameraBrowser(), ptpLog: PTPLog(),
                           ftpInbox: caches.appendingPathComponent("ftp-inbox", isDirectory: true), cloud: cloud)
    }

    static func ftpDestination(_ stored: StoredFTPDestination, keychain: KeychainStore) -> FTPDestination {
        FTPDestination(host: stored.host, port: stored.port, username: stored.username,
                       password: keychain.read(stored.passwordKeychainKey) ?? "",
                       security: FTPSecurity(rawValue: stored.security) ?? .explicitTLS,
                       passive: stored.passive, remoteDirectory: stored.remoteDirectory)
    }

    static func ftpUploader(for stored: StoredFTPDestination, keychain: KeychainStore) -> FTPUploadingBox? {
        let client = FTPClientFactory.make(ftpDestination(stored, keychain: keychain))
        return FTPUploadingBox { data, path in
            try await client.upload(data, to: path, progress: nil)
        }
    }
}
