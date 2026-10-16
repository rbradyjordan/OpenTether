# iOS Camera Tethering Implementation Guide

Brady's blueprint, kept verbatim in substance as the source of truth for
`tether-ios/`. The README records where the implementation deliberately
differs.

## 1. Executive summary

Build the tethering system as a first-class part of the photo editor. One PTP
engine drives two transports:

- **Wired (USB-C):** Apple ImageCaptureCore (`ICDeviceBrowser` /
  `ICCameraDevice`). Capture exclusively via raw `requestSendPTPCommand`.
  Request both control and contents authorization (version-gated for iOS
  18.3+). Do not use `requestTakePicture`.
- **Wireless (Wi-Fi):** in-house PTP/IP over paired `NSInputStream` /
  `NSOutputStream`. Multi-protocol discovery (SSDP + Bonjour + Fuji UDP +
  Ricoh HTTP) plus a Ricoh WebSocket path. Shared PTP engine with
  ByteBuffer/PacketUtil and per-vendor property handlers.

Bidirectional FTP: an on-device FTP server cameras can push to, plus an
FTP/FTPS upload client. Avoid every closed iOS door (no DriverKit,
USBDriverKit, ExternalAccessory, IOKit, UVC, CoreMediaIO). ImageCaptureCore is
the only USB path.

PTP control for Canon, Nikon, Sony, Fuji, Leica, Olympus, Panasonic, Ricoh.
Wireless limited to Canon/Nikon/Sony/Fuji/Ricoh (Leica/Olympus/Panasonic
wired-only). Hasselblad is RAW-decode only.

Compete on AI retouch + credits rather than the tether. Second screen,
Lightroom hot-folder, client gallery, QR delivery, white-label domains and
booking/CRM/invoice stay out of the tether binary.

## 2. Architecture

```
Camera
  ├─ USB-C  → ImageCaptureCore session: requestControl + requestContents auth,
  │            requestSendPTPCommand (raw PTP), cameraDevice:didReceivePTPEvent:
  ├─ Wi-Fi  → discovery: SSDP M-SEARCH+NOTIFY · Bonjour _ptp._tcp · Fuji UDP · Ricoh HTTP
  │            PtpIpClient over NSInput/OutputStream; handshake InitCommand → Ack → InitEvent → …
  │            channels: control / data / event
  │            Ricoh: ws://192.168.0.1/v1/changes + POST /v1/camera/shoot
  └─ FTP push → on-device FTP server + upload client

Capture (SD card or SDRAM) → poll GetEvent → ObjectAdded → GetObjectInfo + GetObject / GetPartialObject
  → CameraCaptureCacheProxy → RAW decode → EffectEngine (3D LUT looks) → EditCanvasView
  ("Show Newest Capture" / "Keep Current Selection") → on-device retouch + optional cloud toning
  → export (credits/quota, watermark) → Photos / share / cloud batch
```

## 3. Implementation details

### 3.1 Wired (ImageCaptureCore)
Link only ImageCaptureCore. `ICDeviceBrowser` with device-type mask, filter by
USB vendor/product ID. Open with `requestOpenSession`, wrapped in a Swift
manager. Request both authorizations; branch on iOS 18.3+. Capture only with
`requestSendPTPCommand:outData:completion:`. Handle frames via
`didReceivePTPEvent` / `didAddItems`. Declare `NSCameraUsageDescription`.
Market wired as the most stable and fastest path.

### 3.2 Wireless PTP/IP
Plain TCP via `getStreamsToHostWithName:port:` (no NWConnection). Handshake,
then demultiplex control/data/event into locked queues. Packet family:
CommandRequest/Response, StartData/Data/EndData, Event. Key bulk transfers by
transaction ID. Do not auto-join the camera AP; use a CoreLocation SSID
monitor and require the phone already be on the camera's Wi-Fi. Determine
port (likely 15740) and byte layout during implementation.

### 3.3 Discovery
`CameraDiscoverer` routing by vendor: SSDP/UPnP (Sony
`urn:schemas-sony-com:service:DigitalImaging:1`; dedupe by UUID, validate
XML), Bonjour (`_ptp._tcp`, `_lnp._tcp.`, `_bonjour._tcp`; brand from hostname
e.g. `nicname.canon.com`; filter APIPA), Fuji (UDP `DISCOVERY * HTTP/1.1`,
`SERVICE: PCSS/1.0`, then an app-side TCP listener the camera dials back to),
Ricoh (HTTP probe to `http://192.168.0.1`). Declare `NSBonjourServices` and
`NSLocalNetworkUsageDescription`.

### 3.4 WebSocket & FTP
WebSocket is Ricoh-only (`NSURLSessionWebSocketTask`, fallback for old
versions) against `ws://192.168.0.1/v1/changes` and `POST /v1/camera/shoot`.
FTP server: inbound push, 220/227/230 responses, passive + active data
channels, user auth, heartbeat + TCP keepalive, rebind on IP change. FTP
client: libcurl for FTP/FTPS; no SFTP strings without libssh2.

### 3.5 PTP protocol, capture, live view
Layered Swift stack: ByteBuffer/PacketUtil → typed datasets (DeviceInfo,
StorageInfo, ObjectInfo, DevicePropDesc) → operation with code / outData /
transactionId / responseCode. Abstract properties as enum / range / other;
per-vendor PropertyId/Data/Handler via factories; map abstract IDs to vendor
codes. Destination-aware capture (card vs SDRAM). Per-vendor sequences: Canon
two-stage shutter, Sony SDIO, generic InitiateCapture / InitiateOpenCapture.
Poll GetEvent until ObjectAdded(InSdram), then GetObjectInfo + GetObject /
GetPartialObject, buffer through the cache proxy. Live view per vendor on a
dedicated thread (Canon EVF, Sony liveview URL over HTTP) with quality and
frame-rate control.

### 3.6 Per-brand matrix

| Brand | PTP control | Wireless control | Wireless discovery | Key gate |
|-------|-------------|------------------|--------------------|----------|
| Canon | ✓ | ✓ | Bonjour `_ptp._tcp`, `nicname.canon.com` | PC mode + two-stage shutter |
| Nikon | ✓ | ✓ | Bonjour PTP-IP | ChangeApplicationMode first |
| Sony | ✓ | ✓ | SSDP sony-com | PTP/MTP switch + single session |
| Fujifilm | ✓ | ✓ | UDP broadcast + TCP listener | tether mode |
| Ricoh | controller only | ✓ HTTP + WebSocket | HTTP probe 192.168.0.1 | wireless-only |
| Leica | ✓ | — | — | wired-only |
| Olympus/OM | ✓ | — | — | wired-only |
| Panasonic | ✓ | — | — | wired-only |

Route by runtime capability flags; no hardcoded per-model allowlist.

### 3.7 On-device pipeline and delivery
RAW decode cr2/cr3/nef/arw/raf/dng + JPEG-XL. Edit engine applying 3D LUT
looks fetched from cloud and cached in SQLite. On-device retouch pipelines;
cloud for AI colour-match toning. Capture → canvas with "Show Newest" vs
"Keep Current Selection", carrying the prior edit stack. Delivery: Photos +
share sheet, resumable background export with credits/quota and free-tier
watermark, cloud batch export. Explicitly omit QR, client gallery,
white-label, hot-folder, second screen, external-SSD routing, booking/CRM.

## 5.6 v1 build order
1. ImageCaptureCore USB session manager + generic PTP import.
2. Transport-agnostic PTP engine; raw-PTP vendor control (Canon/Nikon/Sony,
   then Fuji) with the gates above.
3. JPEG-first review UX: filmstrip, loupe, compare, star/flag/colour, client
   fullscreen.
4. Routing: JPEG → Photos/Files, RAW → SSD or receiver; gallery push.
5. Reliability: cable/power diagnostic, per-camera walkthroughs, mid-shoot
   recovery, tested-camera matrix.
6. Fallbacks: PTP/IP over Wi-Fi + built-in FTP receiver.
7. Workflow hooks: session ↔ booking/client, approved selects → gallery, wrap
   → invoice (in the surrounding platform, not the tether binary).

## 5.7 Legal note
Generic PTP import is safe. Vendor control is the grey area. Generic-PTP-first
with vendor control as a layer. Consult counsel before launch.

## 6. Constants to resolve during development
PTP/IP port; FTP server port; exact PTP hex values and vendor opcodes; USB
VID/PID list or pure capability routing; SSDP group/port; Fuji ports; whether
downloads use ICCameraFile or raw PTP; per-brand capability flags; AI
colour-match wire format. (Resolved values: see README "Open constants".)

## 7. Frameworks and Info.plist
ImageCaptureCore only for USB. Networking via Foundation + libcurl for FTP.
SQLite. AI: MNN (Metal) + ONNX Runtime (CoreML) + OpenCV. Info.plist:
`NSCameraUsageDescription`, `NSLocalNetworkUsageDescription`,
`NSBonjourServices` = `_ptp._tcp`, `_lnp._tcp.`, `_bonjour._tcp`; no
`UISupportedExternalAccessoryProtocols`.
