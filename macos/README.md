# Open Tether for macOS (Rust + Tauri)

A native Mac version of Open Tether: the same free, local-only camera
tethering as the iOS app (the repository root), rewritten in Rust with a Tauri 2
front end. The iOS Swift package `TetherCore` is the reference: every module
here is a port of the matching Swift module, keeping its behaviour, its
protocol details and its tests.

```
macos/
├── crates/
│   ├── tether-types/    shared types: CameraVendor, CameraCapabilities, TransportKind,
│   │                    CameraIdentity, CaptureDestination, LiveViewFrame
│   ├── tether-ptp/      PTP engine, datasets, PTP/IP, USB (ImageCaptureCore via objc2),
│   │                    device properties, VendorHandler + all vendor handlers, HTTP cameras
│   ├── tether-net/      discovery (SSDP, Bonjour, Fuji, Ricoh/GoPro/OSC probes),
│   │                    FTP server (cameras push to us), FTP/FTPS upload client
│   ├── tether-library/  CaptureItem, SQLite store, library (collections, tags, stacks,
│   │                    review editor + undo, commands), looks (.cube, built-ins,
│   │                    colour match), interop (XMP, EXIF, naming, catalogs), export queue
│   └── tether-session/  TetherSession (capture pipeline, reconnect), diagnostics,
│                        the AppCore facade the Tauri commands call
└── app/
    ├── ui/              React + TypeScript + Vite front end (ports the SwiftUI screens)
    └── src-tauri/       Tauri 2 shell: commands/events over tether-session (see docs/IPC.md)
```

## Mapping from the Swift package

| Swift (`Packages/TetherCore/Sources/TetherCore/…`) | Rust |
|---|---|
| `Device/CameraModel.swift` (vendor, capabilities, identity) | `tether-types` |
| `PTP/`, `PTPIP/`, `USB/`, `Device/DeviceProperty.swift`, `Device/VendorHandler.swift` | `tether-ptp` |
| `Vendors/` | `tether-ptp::vendors` |
| `Discovery/`, `FTP/` | `tether-net` |
| `Capture/CaptureItem.swift`, `Store/`, `Library/`, `Looks/`, `Interop/`, `Delivery/` | `tether-library` |
| `Capture/TetherSession.swift`, `ReconnectPolicy.swift`, `CaptureCacheProxy.swift`, `Diagnostics/` | `tether-session` |
| `Tether/` (SwiftUI app) | `app/ui` + `app/src-tauri` |

## Building

Rust comes from Homebrew's rustup: `export PATH=/opt/homebrew/opt/rustup/bin:$PATH`.

```sh
cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
```

Parallel work uses a separate target dir per worker (`CARGO_TARGET_DIR=target-<name>`)
so builds don't wait on each other's lock.

## Mac differences from iOS

- USB goes through ImageCaptureCore on macOS too (`ICCameraDevice
  requestSendPTPCommand`), so the camera is shared politely with
  `ptpcamerad`. Quit Image Capture / Photos / EOS Utility first.
- No Wi-Fi name (SSID) reading: macOS needs location + CoreWLAN; the UI points
  at the Wi-Fi menu instead.
- Sandboxed for the Mac App Store: network client + server (FTP receiver on
  2121, passive 40000–40100, PTP/IP), USB, Photos, user-selected files with
  security-scoped bookmarks.

## Status

See the table at the end of this file, kept current as modules land.

| Piece | State |
|---|---|
| tether-types | done, tested |
| tether-ptp | in progress |
| tether-net | in progress |
| tether-library | in progress |
| tether-session | not started |
| app/ui | in progress |
| app/src-tauri | not started |
