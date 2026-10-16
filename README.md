# Tether — iOS camera tethering

A full-stack tethering system built to the blueprint in `docs/BLUEPRINT.md`:
one PTP engine driving two transports (USB-C through ImageCaptureCore, Wi-Fi
through an in-house PTP/IP stack), multi-protocol discovery, an on-device FTP
receiver plus FTP/FTPS upload, a JPEG-first review UX, routed delivery with
credits and watermarking, and a small cloud service for looks, AI colour
match and batch export.

```
tether-ios/
├── Packages/TetherCore/     Swift package: the whole engine. Builds and tests on Linux.
│   └── Sources/TetherCore/
│       ├── PTP/             ByteBuffer, codes, datasets, PTPEngine, PTPTransport seam
│       ├── PTPIP/           packet family, framer, NSStream + POSIX channels, PTPIPTransport
│       ├── USB/             USB containers, ICDeviceBrowser manager, ImageCaptureCore transport
│       ├── Device/          CameraVendor, capability flags, abstract properties, VendorHandler
│       ├── Vendors/         Canon · Nikon · Sony · Fujifilm · Olympus · Panasonic · Leica · Ricoh
│       ├── Discovery/       SSDP · Bonjour · Fuji UDP + dial-back · Ricoh probe · SSID monitor
│       ├── FTP/             FTP server (cameras push to us) · FTP/FTPS upload clients
│       ├── Capture/         CaptureItem, CaptureCacheProxy, TetherSession actor, reconnect policy
│       ├── Store/           SQLite persistence (sessions, captures, exports, looks, settings)
│       ├── Looks/           .cube 3D LUT parse/sample/blend, LookStack, LookResolver
│       ├── Delivery/        ExportJob, credits model, resumable ExportQueue
│       ├── Cloud/           typed client for the backend contract
│       └── Diagnostics/     cable/power and Wi-Fi checklists
├── Tether/                  SwiftUI app (iOS 17+): every screen on the user journey
├── TetherTests/             app view-model tests
├── project.yml              XcodeGen project (app + tests + local package)
└── backend/                 Rust (axum + SQLite): looks, colour match, credits, batch export
```

## Status

| Piece | State | Verified by |
|-------|-------|-------------|
| PTP engine, datasets, PTP/IP transport | Complete | `swift test` (154 across the package) incl. a loopback PTP/IP camera (handshake, multi-packet data, data-out, events, InitFail) |
| USB (ImageCaptureCore) | Written, compile-guarded for Apple | container framing unit-tested; **not run on a device** |
| Vendor handlers | Written for all eight brands with capability flags from DeviceInfo | scripted-transport tests per vendor; **no real camera yet** |
| Discovery + SSID monitor | Complete | unit tests with canned SSDP/Bonjour/Fuji payloads, loopback Fuji dial-back |
| FTP server + clients | Complete (pure-Swift FTP; FTPS via NSStream TLS on Apple; libcurl client linked on Linux through `Sources/CCurl`) | loopback integration tests, incl. libcurl uploading into our own server |
| Capture pipeline, store, review, export queue, looks | Complete | unit tests (recovery, pairs, show-newest/keep-selection, resumable export, credits quote) |
| Cloud backend | Complete | `cargo test` (36), fmt + clippy clean |
| SwiftUI app | Written; every screen (80 files) | `swiftc -parse` on Linux only. **Needs Xcode to type-check and a device to run**; expect small fix-ups on the first build |

Nothing has touched a real camera. Every vendor opcode or property code that
was not certain is marked `// VERIFY` in the vendor's single code table, so
the first live session with each brand is a one-file fix.

## Design

`docs/DESIGN.md` is the design system (tokens, type, motion, haptics, signature
moments). `docs/prototype.html` is an interactive mock of the shoot screen,
connect flow, client review and export built from those tokens; open it in a
browser to feel the interactions before building in Xcode.

## Build and test

```sh
# Engine (Linux or macOS; needs Swift 6.1 and libsqlite3-dev on Linux)
cd tether-ios/Packages/TetherCore && swift test

# Backend
cd tether-ios/backend && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
TETHER_DEV_PURCHASES=1 cargo run        # http://127.0.0.1:8787, see backend/README.md

# App (macOS with Xcode 16)
cd tether-ios && brew install xcodegen && xcodegen generate && open Tether.xcodeproj
```

The app's Settings screen points at the backend URL (default
`http://127.0.0.1:8787` for the simulator). Onboarding registers the device;
new accounts get 10 free credits a month.

## The user journey

1. **Onboarding** — what Tether does, what it never does (no auto-joining a
   camera's Wi-Fi, no uploads without asking), permissions with real prompts.
2. **Home** — sessions with counts, resume banner for anything interrupted,
   New session (name, capture destination card/iPhone/both, routing JPEG →
   Photos, RAW → Files/cloud, look, workflow tag).
3. **Connect** — USB-C (recommended), Wi-Fi (SSID check, discovery by brand,
   manual IP, handshake progress), FTP push (receiver on/off, credentials,
   per-brand camera instructions, live feed), brand setup guides, and the
   cable/power diagnostic.
4. **Shoot** — canvas with *Show Newest Capture* / *Keep Current Selection*,
   live view, capture (AF / no-AF), exposure bar driven by the camera's own
   choice lists, filmstrip with download rings and RAW+JPEG pairing, rate /
   pick / reject / colour.
5. **Review** — loupe, compare, client review mode (fullscreen, stars and
   flags round-trip, long-press to leave).
6. **Looks** — cloud looks as 3D LUTs applied on device; AI colour match
   (1 credit) returns a LUT for the session.
7. **Export** — scope (all / picks / rated), destination (Photos, Files,
   Share, FTP, cloud batch), options, a credits quote (“N credits · M
   watermarked”), resumable progress with pause/retry.
8. **Credits** — balance, tier, StoreKit packs, free-tier rules.
9. **Settings** — cloud URL, FTP defaults, PTP transaction log, tested-camera
   matrix, legal note (generic PTP import is safe; vendor control is the grey
   area).

## Decisions that differ from the blueprint, and why

- **Core Image / Metal instead of OpenGL ES** for the look engine. OpenGL ES
  has been deprecated on iOS since 12 and is absent on newer platforms;
  `CIColorCube` consumes the same `.cube` tables (`CubeLUT.colorCubeData`).
- **Data phases on the command connection.** Standard PTP/IP has two TCP
  connections; the "data channel" is the StartData/Data/EndData packet family
  on the command connection, demultiplexed by transaction ID. The blueprint's
  InitData step does not exist in the standard; the handshake is the four
  Init packets.
- **AI retouch pipelines (MNN / ONNX / OpenCV) are not bundled.** They need
  model weights and prebuilt frameworks that are not in this repo. The
  `LookRendering` seam is where they plug in.
- **SFTP is absent by design** (needs libssh2). `FTPSecurity` has no SFTP case.
- **Watermark** on the server is a tiled pattern plus badge, not text (the
  `image` crate alone, no font rasteriser). The on-device watermark draws text.

## Open constants (blueprint §6)

| Item | Chosen | Where |
|------|--------|-------|
| PTP/IP TCP port | 15740 | `PTPIPPacket.standardPort` |
| FTP server port | 2121 default, 0 = ephemeral; passive 40000–40100 | `FTPServerConfiguration` |
| SSDP | 239.255.255.250:1900, Sony `DigitalImaging:1` + `ScalarWebAPI:1` | `SSDPDiscoverer` |
| Fuji | UDP 51562 out, TCP 51560 listen (`// VERIFY`) | `FujiDiscoverer` |
| Ricoh | `http://192.168.0.1/v1/props`, `/v1/camera/shoot`, `ws://…/v1/changes` | `RicohHandler`, `RicohProbe` |
| USB vendor IDs | Canon 04A9 · Nikon 04B0 · Sony 054C · Fuji 04CB · Ricoh 25FB · Leica 1A98 · Olympus 07B4 · Panasonic 04DA | `CameraVendor.usbVendorID` (pre-filter only; routing is by capability flags) |
| Downloads | raw PTP only (`GetObject` / `GetPartialObject`, vendor partial opcodes); never `ICCameraFile` | `PTPEngine.download`, vendor `fetchObject` |
| Colour-match wire format | multipart `reference`/`target`/`strength`/`lut_size` → `.cube` URL | `backend/API.md` |

## Next

1. Run the app from Xcode against a real body of each brand, fix the
   `// VERIFY` tables, and move entries in `backend/data/tested-cameras.json`
   from `planned` to `verified`.
2. Sony Wi-Fi live view (Camera Remote API `liveview` stream) and Canon EVF
   frame-rate control.
3. Link libcurl (xcframework) on iOS for FTPS through `CurlFTPClient`, or keep
   the NSStream path.
4. Replace the dev-mode purchase trust with App Store Server API verification.
