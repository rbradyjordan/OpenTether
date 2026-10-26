# Open Tether — iOS camera tethering

Free, local-only camera tethering for iPhone and iPad: one PTP engine
driving USB-C (ImageCaptureCore) and Wi-Fi (an in-house PTP/IP stack), HTTP
drivers for Wi-Fi cameras (Ricoh GR, GoPro, 360° cameras), an on-device FTP
receiver plus FTP/FTPS upload, a JPEG-first review UX, RAW workflows, and
Files / Capture One / Lightroom interop. No account, no servers, no
purchases: everything runs on the device.

```
tether/
├── Packages/TetherCore/     Swift package: the whole engine. Builds and tests on Linux.
│   └── Sources/TetherCore/
│       ├── PTP/             ByteBuffer, codes, datasets, PTPEngine, PTPTransport seam
│       ├── PTPIP/           packet family, framer, NSStream + POSIX channels, PTPIPTransport
│       ├── USB/             USB containers, ICDeviceBrowser manager, ImageCaptureCore transport
│       ├── Device/          CameraVendor, capability flags, abstract properties, VendorHandler
│       ├── Vendors/         Canon · Nikon · Sony · Fujifilm · Olympus · Panasonic · Leica (PTP)
│       │                    Ricoh GR · GoPro · Open Spherical Camera (HTTP) · generic PTP
│       ├── Discovery/       SSDP · Bonjour · Fuji UDP + dial-back · Ricoh / GoPro / OSC probes · SSID monitor
│       ├── FTP/             FTP server (cameras push to us) · FTP/FTPS upload clients
│       ├── Capture/         CaptureItem, CaptureCacheProxy, TetherSession actor, reconnect policy
│       ├── Store/           SQLite persistence (sessions, captures, exports, looks, folders, settings)
│       ├── Looks/           .cube 3D LUTs, built-in looks, on-device colour match, LookResolver
│       ├── Delivery/        ExportJob (RAW output, hot folder), resumable ExportQueue
│       ├── Library/         collections, tags, stacks, WorkspaceMemory, ReviewEditor (undo), Commands
│       ├── Interop/         XMP, EXIF, naming, folder layouts, manifests, Files import plan,
│       │                    Lightroom / Capture One catalog readers
│       └── Diagnostics/     cable/power and Wi-Fi checklists
├── Tether/                  SwiftUI app (iOS 17+, Liquid Glass on iOS 26)
├── TetherTests/             app view-model tests
├── project.yml              XcodeGen project (app + tests + local package)
└── backend/                 Legacy cloud service, no longer used by the app
```

## Mac

`macos/` is a separate, direct-download Mac app (Rust engine ported from
`Packages/TetherCore`, Tauri 2 front end), distributed outside the App Store.
The iOS target also builds for the Mac as a Mac Catalyst app. See
`macos/README.md`.

## Cameras

| Brand | USB-C | Wi-Fi |
|-------|-------|-------|
| Canon EOS | full control | full control (PTP/IP) |
| Canon PowerShot / compacts | import as you shoot | — |
| Nikon Z / DSLR | full control | full control (PTP/IP) |
| Sony α (PC Remote) | full control | full control (PTP/IP) |
| Sony not in PC Remote, RX / ZV | import as you shoot, with a hint | — |
| Fujifilm X / GFX | control | control (camera dials the phone) |
| OM System / Olympus, Panasonic Lumix, Leica | control | — |
| Pentax, Sigma, Hasselblad, Samsung NX | import as you shoot; capture when the body offers PTP capture | — |
| Ricoh GR III / IIIx | import | control (HTTP) |
| GoPro HERO9+ | — | shutter + stills incl. GoPro RAW (Open GoPro API) |
| Ricoh Theta, Insta360 and other 360° | — | shutter + import (Open Spherical Camera API) |
| Any other PTP camera | import as you shoot | — |
| Any camera with FTP upload | — | FTP push into the phone |

Capabilities come from what the body reports (DeviceInfo / API), never from a
model list. Bodies whose vendor mode is off fall back to import-only instead
of failing to connect.

## RAW, Files, Capture One and Lightroom

- **RAW**: originals kept byte-for-byte; RAW+JPEG twins stack and keep one
  base name on export with one XMP sidecar per pair; export RAW as the
  original or developed (CIRAWFilter) to JPEG, HEIF or 16-bit TIFF.
- **Files app**: saved folders anywhere in Files (iCloud Drive, servers,
  USB-C drives) as export destinations; import photos or whole folders with
  their sidecars; "Open in Open Tether" for photos and catalogs.
- **Hot folder**: every frame (and its sidecar) is copied into a saved folder
  as it lands, e.g. a Capture One session's Capture folder or a Lightroom
  Auto Import folder; culling on the phone rewrites the sidecar there.
- **Catalogs**: ratings, picks, labels and keywords sync back from a
  Lightroom Classic `.lrcat` or a Capture One catalog / session, read from a
  private copy (never written). See `docs/INTEROP.md`.

## Status

| Piece | State | Verified by |
|-------|-------|-------------|
| PTP engine, datasets, PTP/IP transport | Complete | `swift test` incl. a loopback PTP/IP camera |
| USB (ImageCaptureCore) | Written, compile-guarded for Apple | container framing unit-tested; **not run on a device** |
| Vendor handlers (PTP and HTTP) | Written; capability flags from the body | scripted-transport / scripted-HTTP tests per brand; **no real camera yet** |
| Discovery, FTP server + clients | Complete | unit + loopback integration tests |
| Capture, store, review, export, looks | Complete | unit tests (recovery, pairs, show-newest, resumable export, RAW naming) |
| Library, interop, Files import, catalogs | Complete | scenario tests, Lightroom / Capture One catalog fixtures |
| SwiftUI app | Builds in Xcode; walked through in the iOS Simulator (FTP push session, hot folder into a Capture One session, catalog-free looks) | the Xcode app-test target did not start on this machine (simulator runner) |

Nothing has touched a real camera. Every vendor opcode or endpoint that was
not certain is marked `// VERIFY` in that vendor's code table.

## Design

`docs/DESIGN.md` is the design system: always dark, graphite with a
lens-blue accent, flat Liquid Glass surfaces.

## Build and test

```sh
# Engine (Linux or macOS; Swift 6.1, libsqlite3-dev on Linux)
cd Packages/TetherCore && swift test

# App (macOS with Xcode)
brew install xcodegen && xcodegen generate && open Tether.xcodeproj
```

## Decisions

- **Core Image / Metal** for looks and RAW development (`CIColorCube`,
  `CIRAWFilter`).
- **Data phases on the command connection** for PTP/IP (the standard has no
  separate data socket).
- **No writing into Lightroom or Capture One catalogs**: they are
  undocumented databases the desktop app keeps open. Interop is XMP sidecars,
  folder layouts those apps watch, and read-only catalog sync.
- **SFTP is absent by design** (needs libssh2).

## Open constants

| Item | Chosen | Where |
|------|--------|-------|
| PTP/IP TCP port | 15740 | `PTPIPPacket.standardPort` |
| FTP server port | 2121 default; passive 40000–40100 | `FTPServerConfiguration` |
| SSDP | 239.255.255.250:1900, Sony | `SSDPDiscoverer` |
| Fuji | UDP 51562 out, TCP 51560 listen (`// VERIFY`) | `FujiDiscoverer` |
| Ricoh GR | `http://192.168.0.1/v1/…` | `RicohHandler`, `RicohProbe` |
| GoPro | `http://10.5.5.9:8080/gopro/…` | `GoProHandler`, `HTTPCameraProbe` |
| OSC | `http://192.168.1.1` / `192.168.42.1`, `/osc/…` | `OSCHandler`, `HTTPCameraProbe` |
| USB vendor IDs | Canon 04A9 · Nikon 04B0 · Sony 054C · Fuji 04CB · Ricoh/Pentax 25FB · Leica 1A98 · Olympus 07B4 · Panasonic 04DA · Sigma 1003 · Samsung 04E8 · Hasselblad 2A5F · GoPro 2672 | `CameraVendor.usbVendorID` (pre-filter only) |

## Next

1. Run against a real body of each brand and fix the `// VERIFY` tables.
2. Pentax and Sigma remote-control extensions once verified on hardware.
3. GoPro / OSC live preview.
4. Link libcurl on iOS for FTPS, or keep the NSStream path.
