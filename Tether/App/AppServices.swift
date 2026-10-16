import Foundation
import TetherCore

/// Wires the core package to the platform adapters. Built once at launch.
struct AppServices {
    let store: SessionStore
    /// Between-session memory; the export queue reads the metadata profile from it.
    let memory: WorkspaceMemory
    let cache: CaptureCacheProxy
    let keychain: KeychainStore
    let previews: ImageIOPreviewGenerator
    let renderer: CoreImageLookRenderer
    let lookResolver: LookResolver
    let exportQueue: ExportQueue
    let discovery: CameraDiscoverer
    let ssid: any SSIDProviding
    let usbBrowser: USBCameraBrowser
    let ptpLog: PTPLog
    let ftpInbox: URL

    static func make() throws -> AppServices {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let store = try SessionStore(path: support.appendingPathComponent("tether.sqlite").path)
        let memory = WorkspaceMemory(store: store)
        let cache = CaptureCacheProxy(storageRoot: support.appendingPathComponent("Captures", isDirectory: true))
        let keychain = KeychainStore()
        // Every look is on the device: the built-ins, imported cubes and colour matches.
        BuiltInLooks.install(into: store)
        let resolver = LookResolver(store: store)
        let renderer = CoreImageLookRenderer()
        let sink = RoutingExportSink(photos: PhotosExportSink(store: store), files: FilesExportSink(store: store), folders: FolderExportSink(store: store))
        let queue = ExportQueue(store: store, cache: cache, sink: sink, renderer: renderer, looks: resolver, memory: memory,
                                ftpClientFactory: { dest in AppServices.ftpUploader(for: dest, keychain: keychain) })
        VendorRegistry.installBuiltIns()
        return AppServices(store: store, memory: memory, cache: cache, keychain: keychain,
                           previews: ImageIOPreviewGenerator(), renderer: renderer, lookResolver: resolver,
                           exportQueue: queue, discovery: CameraDiscoverer(), ssid: CoreLocationSSIDMonitor(),
                           usbBrowser: USBCameraBrowser(), ptpLog: PTPLog(),
                           ftpInbox: caches.appendingPathComponent("ftp-inbox", isDirectory: true))
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
