# Open Tether for macOS — IPC contract (UI ⇄ Rust)

The React front end (`app/ui`) talks to the Rust engine only through the
Tauri 2 commands, events and the `tether` URI scheme described here. The
Tauri shell (`app/src-tauri`) implements this file on top of the
`tether-session` facade; nothing in the UI reaches the crates any other way.

The TypeScript side of the contract lives in `app/ui/src/api/`:
`types.ts` (every JSON shape), `backend.ts` (every command and event),
`tauri.ts` (the real client) and `mock/` (an in-browser implementation used
when `window.__TAURI_INTERNALS__` is absent, which is also a working
reference for the behaviour of each command). Sections 4–6 below are
generated from `backend.ts` / `types.ts`.

## 1. Conventions

- **Command names** are the snake_case form of the TS method:
  `sessionsList` → `sessions_list`, `reviewRate` → `review_rate`.
- **Arguments** are one JSON object. Its keys are camelCase; Tauri 2 maps
  them onto the Rust function's snake_case parameters by default
  (`{ captureId }` → `capture_id: String`). Commands without arguments take
  `{}`.
- **JSON shapes** (section 6): structs use `#[serde(rename_all = "camelCase")]`.
  Plain enums are the Swift raw values (`"usb"`, `"ptpip"`, `"ricohHTTP"`,
  `"ftpPush"`, `"http"`; `"none" | "pick" | "reject"`; …). Enums with data
  are internally tagged on `kind`, e.g.
  `#[serde(tag = "kind", rename_all = "camelCase")] enum CaptureState { Announced, Downloading { received: u64, total: Option<u64> }, Ready, Failed { message: String } }`
  → `{ "kind": "downloading", "received": 12, "total": 40 }`.
- **Dates** are RFC 3339 strings in UTC (`chrono::DateTime<Utc>` default).
- **Optionals** are sent as `null`, never omitted, unless the type marks the
  field `?:` (only `CaptureFilter` fields, `reveal_in_finder` args and
  `ToastMessage.action`).
- **Ids** are opaque strings (UUIDs in the store). The UI never parses them.
- **Store-internal fields are not sent**: PTP object handles, relative file
  paths, keychain keys and bookmarks stay in Rust. Files are reached through
  the URI scheme (section 3) or by id (`reveal_in_finder`, exports).
- **`CameraCapabilities`** is the raw `u32` bit mask, exactly as
  `tether_types::CameraCapabilities` serializes it.
- **`PTPValue`** (property raw values) is a JSON number for integer values
  and a string for string values. The UI never interprets it; it only sends
  back one of `PropertyDescriptor.form.choices[].raw`.
- **Ordering**: a command that changes state emits its events *before*
  resolving, so a UI waiting on the promise already has the event applied.
  Events for one entity are delivered in order.

## 2. Errors

Every command returns `Result<T, IpcError>` where

```rust
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IpcError { pub code: String, pub message: String }
```

`message` is one user-facing sentence (the UI shows the first sentence in
toasts and in the connect / reconnect cards). `code` is stable and
machine-readable:

| code | meaning |
|---|---|
| `notFound` | session / capture / collection / destination id unknown |
| `noShoot` | a `shoot_*` command with no active shoot |
| `nothingSelected` | a review command with an empty `ids` |
| `nothingToExport` | export request matched no files |
| `unsupported` | the camera / connection cannot do this (no remote shutter, no live view…) |
| `notReady` | camera busy (capture in flight, still preparing) |
| `readOnly`, `invalidValue` | `shoot_set_property` rejected |
| `deviceGone` | USB device disappeared before / while connecting |
| `busy` | another app holds the camera (Image Capture, EOS Utility…) |
| `connectFailed` | connect / reconnect failed (message says why) |
| `cancelled` | `connect_cancel` / `shoot_reconnect_cancel` aborted the attempt |
| `ftpFailed` | FTP destination test / upload failed |
| `permissionDenied` | a macOS permission the action needs is denied |
| `io` | file system error |
| `internal` | anything else (bug) |

The client wraps rejections in `BackendError { code, message }`; a plain
string rejection is treated as `{ code: "internal", message }`.

## 3. Images: the `tether` URI scheme

Image bytes never travel over IPC. The shell registers an asynchronous
custom protocol (`tauri::Builder::register_asynchronous_uri_scheme_protocol("tether", …)`).
On macOS the webview loads it as `tether://localhost/<path>` (Windows/Linux
WebView2 would use `http://tether.localhost/<path>`; the client picks
by platform). The UI only builds these URLs:

| URL | Response |
|---|---|
| `tether://localhost/capture/<id>/thumb?rev=<n>` | JPEG, long edge ≈ 360 px (grid, filmstrip, look tiles). For RAW: the embedded / rendered proxy. |
| `tether://localhost/capture/<id>/preview?rev=<n>` | JPEG, long edge ≈ 1600–2048 px (canvas, loupe, inspector, compare, client review). |
| `tether://localhost/capture/<id>/original?rev=<n>` | The original file bytes with its real `Content-Type` (`image/jpeg`, `image/heic`, `image/x-canon-cr3`…). Used for "open original" only; the UI displays `preview`. |
| `…/thumb` or `…/preview` with `&look=<lookId>&strength=<0.00–1.00>` | The same rendition rendered through that look (CoreImage / LUT, `LookRenderCache` equivalent). Cache by (id, rev, variant, look, strength). |
| `tether://localhost/liveview/<sequence>.jpg` | The live-view JPEG with that sequence number (keep the last 2–3 frames; 404 for older). |

Rules:

- `<id>` is the capture id, URL-encoded. `rev` is `CaptureItem.revision`;
  bump `revision` (and emit `capture:updated`) whenever the file, proxy or
  thumbnail changes so the webview reloads it. Responses for a given
  (id, rev, look, strength) are immutable: send
  `Cache-Control: max-age=31536000, immutable`.
- While a capture is still downloading, `thumb` may return the camera's
  embedded thumbnail; if nothing exists yet return `404` (the UI shows a
  ring and waits for `capture:updated`).
- Unknown id → `404`. Rendering failure → `500` with a short text body.
- Thumbnails are rendered once and kept on disk next to the session
  (`CaptureCacheProxy`), previews on demand with an LRU memory cache.
- The CSP in `tauri.conf.json` must allow it:
  `"img-src 'self' tether: http://tether.localhost data: blob:"`.

<!-- Command and event tables are generated from app/ui/src/api/backend.ts; keep them in sync. -->

## 4. Commands

113 commands. Rust name = snake_case of the TS method. Args are one JSON object (keys camelCase in JSON; Tauri maps them to snake_case parameters). Every command returns `Result<T, IpcError>`.

### App

| Command | Args | Returns | Behaviour |
|---|---|---|---|
| `app_info` | `—` | `AppInfo` | Version, build and platform for About/Settings. `backend` is always `"tauri"` from Rust. |
| `settings_get` | `—` | `AppSettings` | Small persisted preferences (onboarding done, FTP receiver login). |
| `settings_update` | `{ patch: Partial<AppSettings> }` | `AppSettings` | Merge `patch` into the settings and persist. Changing the FTP login restarts a running receiver (emit `ftp:status`). |
| `permissions_status` | `—` | `Record<PermissionKind, PermissionState>` | Current state of the optional macOS permissions shown in onboarding. |
| `permissions_request` | `{ kind: PermissionKind }` | `PermissionState` | Trigger the system prompt (local network: briefly start discovery; photos: PHPhotoLibrary add-only). Resolves with the new state. |
| `metadata_profile_get` | `—` | `MetadataProfile` | Creator/copyright/caption/keyword settings used for XMP (WorkspaceMemory.metadataProfile). |
| `metadata_profile_set` | `{ profile: MetadataProfile }` | `void` | Persist the metadata profile. |
| `xmp_preview` | `{ captureId: string \| null }` | `{ filename: string \| null; packet: string \| null }` | The XMP packet an export would write for `captureId` (or the newest capture when null). `packet` is null when the library is empty. |
| `view_state_get` | `{ key: string }` | `ViewState \| null` | Remembered filter/sort/zoom/stacking for a library source (`key` = `sourceKey(source)`, e.g. `collection:builtin.all`). Null when never saved. |
| `view_state_set` | `{ key: string; state: ViewState }` | `void` | Remember the view state for `key`; also records `key` as the last source (see `last_source_get`). |
| `last_source_get` | `—` | `string \| null` | The last library source key the user looked at, for "Continue where you left off". |
| `recents_get` | `—` | `Recents` | Recently used tags and collections (most recent first). |
| `export_memory_get` | `—` | `ExportMemory` | The last export's destination, options and scope id ("Export like last time"). |
| `dialog_pick` | `{ kind: DialogKind; multiple: boolean }` | `string[]` | Show the native open panel. `files`: images/RAW/movies (+folders); `folder`: one folder (security-scoped bookmark kept by Rust); `catalog`: .lrcat / .cocatalog / .cosessiondb; `cube`: .cube LUTs. Resolves with absolute paths, empty array when cancelled. |
| `reveal_in_finder` | `{ captureId?: string; path?: string }` | `void` | Reveal a capture's original (`captureId`) or any path in Finder. |
| `open_wifi_settings` | `—` | `void` | Open System Settings › Wi-Fi. |
| `ptp_log` | `—` | `PtpLogLine[]` | Last ~300 lines of the PTP conversation log. |

### Sessions

| Command | Args | Returns | Behaviour |
|---|---|---|---|
| `sessions_list` | `—` | `SessionSummary[]` | All sessions, newest first, each with counts and the three newest ready captures. |
| `session_get` | `{ id: string }` | `SessionSummary` | One session summary. Error `notFound` when it no longer exists. |
| `session_captures` | `{ id: string }` | `CaptureItem[]` | Every capture in a session in sequence order (any state). |
| `session_create` | `{ draft: NewSessionDraft }` | `ShootSession` | Create a session from the New Session form. When `templateId` is set, record a template use. Emits `sessions:changed`. |
| `session_rename` | `{ id: string; name: string }` | `ShootSession` | Rename (also the live session, if it is the open shoot: emit `shoot:session`). Emits `sessions:changed`. |
| `session_delete` | `{ id: string }` | `void` | Delete the session, its captures and files. Ends the shoot first if it is the open one. Emits `sessions:changed` and `library:changed`. |
| `session_dismiss_interrupted` | `{ id: string }` | `void` | Mark an interrupted session ended without resuming it. |
| `session_resume` | `{ id: string }` | `ShootState` | Re-open a stored session as the active shoot with no camera; status is `disconnected` with a reconnect strategy from the stored transport (FTP sessions restart the receiver and are live straight away). Emits `shoot:started`. |
| `session_manifest` | `{ id: string }` | `{ jsonPath: string; csvPath: string }` | Write the session manifest (JSON + CSV: files, ratings, tags, collections) and return the paths. |
| `session_defaults` | `—` | `NewSessionDraft & { namePattern: string }` | "Last settings" for the New Session form plus the remembered name pattern. |
| `templates_list` | `—` | `SessionTemplate[]` | Session templates, most recently used first. |
| `template_save` | `{ template: SessionTemplate }` | `SessionTemplate` | Insert or update a template. |
| `template_delete` | `{ id: string }` | `void` | Delete a template. |
| `template_from_session` | `{ sessionId: string }` | `SessionTemplate` | A new (unsaved) template drafted from a session's settings. |
| `template_suggest` | `{ cameraId: string \| null }` | `string \| null` | Template id to preselect for this camera (WorkspaceMemory), or null. |
| `template_expand_name` | `{ pattern: string; templateName: string; cameraName: string \| null }` | `string` | Expand a session name pattern (`{date} {name} {camera} {n} {weekday}`). |

### Connect: USB

| Command | Args | Returns | Behaviour |
|---|---|---|---|
| `usb_devices` | `—` | `UsbCandidate[]` | Cameras currently on the USB bus (ICDeviceBrowser). Starts the browser if needed; later changes arrive as `usb:devices`. |
| `usb_authorization` | `—` | `UsbAuthorization` | Whether the app may send PTP to cameras (no prompt). |
| `usb_request_authorization` | `—` | `UsbAuthorization` | Ask for camera control access (prompt if undetermined). |
| `usb_connect` | `{ candidateId: string; sessionId: string \| null }` | `ShootState` | Connect to a USB camera and make it the active shoot. Progress streams as `connect:progress`; on success resolves with the shoot and emits `shoot:started`. Error codes: `deviceGone`, `connectFailed`, `cancelled`, `busy` (another app holds the camera). |

### Connect: Wi-Fi

| Command | Args | Returns | Behaviour |
|---|---|---|---|
| `discovery_start` | `—` | `DiscoveryState` | Start SSDP/Bonjour/Fuji/Ricoh/GoPro/OSC discovery (idempotent). Returns what is known now; updates arrive as `discovery:cameras`. |
| `discovery_stop` | `—` | `void` | Stop discovery (the Wi-Fi screen closed). |
| `discovery_add_manual` | `{ host: string; port: number; vendor: CameraVendor \| null }` | `DiscoveredCamera` | Add a manually entered camera to the discovered list (emits `discovery:cameras`). |
| `wifi_connect` | `{ cameraId: string; sessionId: string \| null }` | `ShootState` | Connect to a discovered camera (PTP/IP, Ricoh HTTP or GoPro/OSC HTTP by its transport) and make it the active shoot. Same progress/events/errors as `usb_connect`. |
| `network_info` | `—` | `NetworkInfo` | Wi-Fi name (always null on macOS), local IPv4 addresses, camera-network guess. |
| `known_cameras` | `—` | `KnownCamera[]` | Cameras connected before, most recent first. |
| `connect_cancel` | `—` | `void` | Abort the connect attempt in progress (the pending `*_connect` rejects with `cancelled`). |

### Connect: FTP receiver

| Command | Args | Returns | Behaviour |
|---|---|---|---|
| `ftp_receiver_status` | `—` | `FtpReceiverStatus` | State of the built-in FTP server and the last received files. |
| `ftp_receiver_start` | `—` | `FtpReceiverStatus` | Start the FTP server with the saved login/port. Emits `ftp:status`. |
| `ftp_receiver_stop` | `—` | `FtpReceiverStatus` | Stop the FTP server. Emits `ftp:status`. |
| `ftp_receiver_start_session` | `{ sessionId: string \| null }` | `ShootState` | Start the receiver if needed and open an FTP-push shoot (no camera; files arrive as captures). Emits `shoot:started`. |

### Connect: demo, diagnostics

| Command | Args | Returns | Behaviour |
|---|---|---|---|
| `demo_start` | `—` | `ShootState` | Start the demo shoot (no camera): sample frames arrive every few seconds through the normal capture pipeline. If a shoot is open, returns it. |
| `diagnostics_run` | `{ wired: boolean; host: string \| null; port: number \| null }` | `DiagnosticReport` | Run the wired (USB) or wireless (host/port) checklist. Each step emits `diagnostics:update`; resolves with the final report. |

### Shoot (the one active session)

| Command | Args | Returns | Behaviour |
|---|---|---|---|
| `shoot_state` | `—` | `ShootState \| null` | Snapshot of the active shoot, or null. |
| `shoot_capture` | `{ autofocus: boolean }` | `void` | Fire the shutter (with or without AF). Status goes `capturing` → `ready`; the frame arrives as `capture:added`/`capture:updated`. Errors: `unsupported` (no remote capture), `notReady`, `noShoot`. |
| `shoot_set_property` | `{ property: TetherProperty; raw: PTPValue }` | `void` | Set a camera property to one of its `choices[].raw`. The new descriptors arrive as `shoot:properties`. Errors: `readOnly`, `invalidValue`. |
| `shoot_live_view_start` | `—` | `void` | Start live view; resolves when the camera accepted it. Frames arrive as `liveview:frame`; `shoot:liveview` reports the state. |
| `shoot_live_view_stop` | `—` | `void` | Stop live view. |
| `shoot_focus` | `{ x: number; y: number }` | `FocusResult` | One-shot AF at a point of the live-view frame (0…1). Resolves with the camera's verdict. |
| `shoot_focus_track_start` | `{ x: number; y: number }` | `void` | Press-and-hold: AF tracks at the point until `shoot_focus_track_stop`. |
| `shoot_focus_track_stop` | `—` | `void` | Release tracking AF. |
| `shoot_select` | `{ captureId: string \| null }` | `void` | Show this capture on the canvas (null = follow newest). Emits `shoot:selection`. |
| `shoot_set_follow_newest` | `{ on: boolean }` | `void` | Session's "show newest capture" setting. Emits `shoot:session`. |
| `shoot_set_look` | `{ look: LookStack }` | `void` | The live look stack (canvas, new captures, exports). Emits `shoot:look`. |
| `shoot_set_destination` | `{ destination: CaptureDestination }` | `void` | Where the camera writes (card / Mac / both). Emits `shoot:session` and `shoot:properties`. |
| `shoot_set_routing` | `{ routing: RoutingRules }` | `void` | Export routing and hot folder (`liveFolderId`). Emits `shoot:session`. |
| `shoot_restore_offer` | `{ accept: boolean }` | `void` | Accept or decline the "use last time's look" banner (clears `restoreOffer`). |
| `shoot_import_files` | `{ paths: string[] }` | `{ imported: number }` | Import files into the open session (sidecars matched). |
| `shoot_delete_capture` | `{ captureId: string }` | `void` | Delete one capture of the open shoot (file and row). Emits `capture:removed`. |
| `shoot_reconnect` | `—` | `ShootState` | Run the session's reconnect strategy. Status goes `reconnecting` → `ready` (resolves with the new snapshot) or back to `disconnected` (rejects `connectFailed`/`cancelled`). |
| `shoot_reconnect_cancel` | `—` | `void` | Abort a reconnect in progress. |
| `shoot_end` | `—` | `void` | End the shoot: close the link, mark the session ended. Emits `shoot:ended` and `sessions:changed`. |

### Library

| Command | Args | Returns | Behaviour |
|---|---|---|---|
| `library_sources` | `—` | `LibrarySources` | Everything the sidebar shows: built-in, pinned, manual and smart collections, sessions, cameras, and a count of ready captures per source key. |
| `library_query` | `{ query: LibraryQuery }` | `LibraryPage` | One page of captures for a source AND a filter (the grid). `filter.readyOnly` defaults to false here so downloading frames show; `total` counts all matches. |
| `library_preview_count` | `{ filter: CaptureFilter }` | `number` | How many ready captures match a rule (smart-collection editor). |
| `capture_details` | `{ id: string }` | `CaptureDetails` | Inspector extras: tags, manual collections containing it, export history, EXIF. |
| `tags_suggest` | `{ prefix: string }` | `string[]` | Known tags starting with `prefix` (normalized: lowercase, no `#`, spaces → `-`). |
| `review_rate` | `{ ids: string[]; stars: number }` | `UndoState` | Set the star rating (0 clears) on `ids` and their RAW/JPEG twins. One undo step. Emits `captures:changed` and `undo:state`; returns the new undo state. Error `nothingSelected` on empty ids. |
| `review_flag` | `{ ids: string[]; flag: CaptureFlag }` | `UndoState` | Pick / reject / unflag `ids` and their twins. One undo step; same events. |
| `review_label` | `{ ids: string[]; label: ColorLabel }` | `UndoState` | Colour label on `ids` (twins not included, as on iOS). One undo step; same events. |
| `review_add_tags` | `{ ids: string[]; tags: string[] }` | `UndoState` | Add tags to `ids`; only newly added (capture, tag) pairs are undone. Same events. |
| `review_remove_tags` | `{ ids: string[]; tags: string[] }` | `UndoState` | Remove tags from `ids`. Same events. |
| `review_undo` | `—` | `UndoResult \| null` | Undo the last review edit; resolves with its title and count (for the toast), or null when there was nothing to undo. |
| `review_redo` | `—` | `UndoResult \| null` | Redo; same shape as undo. |
| `undo_state` | `—` | `UndoState` | Titles of the next undo / redo (null = disabled). |
| `collection_add_items` | `{ ids: string[]; collectionId: string }` | `UndoState` | Add captures to a manual collection (one undo step). Emits `captures:changed`, `undo:state`, `library:changed`. |
| `collection_remove_items` | `{ ids: string[]; collectionId: string }` | `UndoState` | Remove captures from a manual collection (one undo step). |
| `collection_create` | `{ name: string; ids: string[]; symbol: string; tint: ColorLabel }` | `Collection` | Create a manual collection, optionally with captures ("New collection from selection"). |
| `collection_save` | `{ collection: Collection }` | `Collection` | Insert or update a collection (name, symbol, tint, pin, smart rule). Built-ins keep their rule. Emits `library:changed`. |
| `collection_delete` | `{ id: string }` | `void` | Delete a non-built-in collection (photos stay). Emits `library:changed`. |
| `collection_toggle_pin` | `{ id: string }` | `void` | Pin / unpin (built-ins too). |
| `collection_move` | `{ id: string; toIndex: number }` | `void` | Reorder a manual collection to `toIndex`. |
| `captures_delete` | `{ ids: string[] }` | `void` | Move captures (and their twins) to the Trash and remove them from the library. |
| `library_import` | `{ paths: string[]; sessionId: string \| null }` | `{ imported: number }` | Import files/folders into `sessionId`, or into a new "Import <date>" session when null. |
| `catalog_read` | `{ path: string }` | `CatalogPreview` | Read a Lightroom Classic / Capture One catalog (read-only copy) and diff it against the library. |
| `catalog_apply` | `{ changes: CatalogChange[] }` | `{ applied: number }` | Apply catalog changes through the review editor, grouped by value (one undo step per group). |

### Looks

| Command | Args | Returns | Behaviour |
|---|---|---|---|
| `looks_list` | `—` | `LookDescriptor[]` | Built-in, imported and colour-matched looks. |
| `looks_import_cube` | `{ paths: string[] }` | `{ added: number }` | Add .cube LUTs as looks. Emits `looks:changed`. |
| `look_color_match` | `{ referenceId: string; targetId: string; strength: number }` | `LookDescriptor` | Compute a colour-match LUT from a reference and target frame, save it as a look. Emits `looks:changed`. |

### Export

| Command | Args | Returns | Behaviour |
|---|---|---|---|
| `export_plan` | `{ request: ExportRequest }` | `ExportPlan` | What `export_enqueue` would deliver for this request: counts and the first three delivered relative paths (naming + layout applied). Cheap; called on every form change. |
| `export_enqueue` | `{ request: ExportRequest }` | `ExportJob[]` | Create one job per session for the request, queue them, remember the settings as "last export". Emits `export:job` per job. Error `nothingToExport`. |
| `export_again` | `{ captureIds: string[] }` | `ExportJob[]` | "Export like last time" over `captureIds` with the remembered destination/options/scope. |
| `export_jobs` | `{ sessionId: string \| null }` | `ExportJob[]` | Jobs, newest first, optionally for one session. |
| `export_pause_all` | `—` | `void` | Pause the queue (running jobs → paused). Emits `export:job`. |
| `export_resume_all` | `—` | `void` | Resume the queue. |
| `export_retry` | `{ jobId: string }` | `void` | Re-queue a job's failed items. |
| `export_reveal` | `{ jobId: string }` | `void` | Reveal a finished job's files in Finder. |
| `ftp_destinations_list` | `—` | `FtpDestination[]` | Saved FTP/FTPS destinations (no passwords). |
| `ftp_destination_save` | `{ destination: FtpDestination; password: string \| null }` | `FtpDestination` | Insert (empty `id`) or update a destination; `password` non-null replaces the Keychain entry. |
| `ftp_destination_delete` | `{ id: string }` | `void` | Delete a destination and its Keychain password. |
| `ftp_destination_test` | `{ destination: FtpDestination; password: string }` | `string` | Log in, check the remote directory is writable; resolves with a one-line result, rejects `ftpFailed` with the reason. |
| `ftp_destination_password` | `{ id: string }` | `string \| null` | The saved password (Keychain) to prefill the editor. |
| `folder_destinations_list` | `—` | `FolderDestination[]` | Saved folders (security-scoped bookmarks) for exports and the hot folder. |
| `folder_destination_add` | `{ path: string }` | `FolderDestination` | Save a folder picked with `dialog_pick({kind: "folder"})`; the kind is guessed (a `.cosessiondb` inside → Capture One session). |
| `folder_destination_set_kind` | `{ id: string; kind: FolderKind }` | `FolderDestination` | Mark a folder as plain / Capture One session / Lightroom Auto Import. |
| `folder_destination_delete` | `{ id: string }` | `void` | Forget a saved folder. |

## 5. Events

28 events, emitted with `app.emit(name, payload)` to all windows. Payload JSON shapes are in section 6.

| Event | Payload | When |
|---|---|---|
| `shoot:started` | `ShootState` | A shoot became active (connect, demo, FTP session, resume, restore-offer answered) or was rebuilt after reconnect. Full snapshot. |
| `shoot:ended` | `{ sessionId: string }` | The active shoot ended. |
| `shoot:status` | `{ status: ShootStatus }` | Link status changed. `disconnected` carries a one-sentence reason (the UI toasts it and opens the reconnect sheet). |
| `shoot:session` | `ShootSession` | The live session record changed (rename, follow-newest, destination, routing, capture count). |
| `shoot:identity` | `CameraIdentity \| null` | Camera identity learnt or changed (e.g. after reconnecting to a different body). |
| `shoot:properties` | `PropertyDescriptor[]` | Full property list after any change (set, camera dial turned, battery). |
| `shoot:selection` | `{ captureId: string \| null }` | The displayed capture changed (auto-follow of a new frame, or `shoot_select`). |
| `shoot:liveview` | `{ active: boolean }` | Live view started or stopped (also when the camera stops it). |
| `shoot:look` | `LookStack` | The live look stack changed. |
| `shoot:downloads` | `{ inFlight: number }` | Number of captures still transferring (status pill "3 ↓"). |
| `capture:added` | `CaptureItem` | A new capture announced in the active shoot (state `announced` or `downloading`). |
| `capture:updated` | `CaptureItem` | Pipeline change of an active-shoot capture: download progress (throttle to ~5/s per item), `ready`, `failed`, preview/thumbnail rendered (bump `revision`). |
| `capture:removed` | `{ id: string; sessionId: string }` | A capture of the active shoot was deleted. |
| `captures:changed` | `CaptureItem[]` | Review edits (rating, flag, label, tags, collections, undo/redo, catalog sync) for any captures, live or not. Sent after the store write. |
| `liveview:frame` | `LiveViewFrame` | A live-view frame is ready. Rust sends `{ sequence, width, height }` only; the JPEG is fetched from `tether://localhost/liveview/<sequence>.jpg` (the client adds `url`). Send at most ~15/s; keep the latest 2–3 frames. |
| `connect:progress` | `ConnectProgress` | Step list of the connect attempt in progress (`usb_connect`, `wifi_connect`). Sent on every step change, including the failure. |
| `usb:devices` | `UsbCandidate[]` | The USB camera list changed. |
| `discovery:cameras` | `DiscoveredCamera[]` | The discovered Wi-Fi camera list changed (full list). |
| `ftp:status` | `FtpReceiverStatus` | FTP receiver state changed (started, stopped, client connected/disconnected, error). |
| `ftp:file` | `FtpReceivedFile` | A file finished arriving over FTP (also becomes a capture in an FTP shoot). |
| `export:job` | `ExportJob` | A job was created or progressed (throttle to ~5/s per job). |
| `export:finished` | `ExportJob` | A job reached `completed` or `failed`. Also send a `toast`. |
| `diagnostics:update` | `DiagnosticReport` | A diagnostic step started or finished (full report each time). |
| `undo:state` | `UndoState` | Undo/redo titles changed. |
| `library:changed` | `{ reason: string }` | Something the library grid or sidebar counts depend on changed outside a review edit (capture became ready, import, delete, collection edit, export finished). The UI re-queries; debounce to ≤ 4/s. |
| `sessions:changed` | `{ reason: string }` | The session list changed (created, renamed, deleted, ended, resumed). |
| `looks:changed` | `LookDescriptor[]` | The look list changed (full list). |
| `toast` | `ToastMessage` | A one-line message for the user (export finished, auto-export queued, warnings). `symbol` is an SF Symbol name; `action.command` is a UI command id (currently `shoot.showNewest`). |

## 6. Types

TypeScript notation for the JSON. `string | null` = `Option<String>` serialized as `null` (never omitted). `?:` fields may be omitted or null. Enum strings are exact (serde `rename`).

```ts
type ISODate = string;

// ── Camera

type CameraVendor =
  | "canon" | "nikon" | "sony" | "fujifilm" | "ricoh" | "leica" | "olympus" | "panasonic"
  | "hasselblad" | "generic" | "pentax" | "sigma" | "samsung" | "gopro" | "osc";
type TransportKind = "usb" | "ptpip" | "ricohHTTP" | "ftpPush" | "http";
interface CameraIdentity {
  id: string;
  vendor: CameraVendor;
  manufacturer: string;
  model: string;
  serialNumber: string;
  firmware: string;
  transport: TransportKind;
  capabilities: number;
}
type CaptureDestination = "card" | "host" | "both";
type TetherProperty =
  | "aperture" | "shutterSpeed" | "iso" | "exposureCompensation" | "whiteBalance" | "colorTemperature"
  | "exposureProgram" | "driveMode" | "meteringMode" | "focusMode" | "imageQuality" | "imageSize"
  | "captureDestination" | "batteryLevel" | "liveViewEnabled" | "flashMode" | "pictureStyle"
  | "storageFreeImages" | "lensName" | "shutterCount";
/** A PTP value as JSON: integers stay numbers, strings stay strings. Opaque to the UI. */
type PTPValue = number | string;
interface PropertyChoice {
  raw: PTPValue;
  display: string;
}
type PropertyForm =
  | { kind: "choices"; choices: PropertyChoice[] }
  | { kind: "range"; min: number; max: number; step: number }
  | { kind: "other" };
interface PropertyDescriptor {
  property: TetherProperty;
  raw: PTPValue;
  display: string;
  isWritable: boolean;
  form: PropertyForm;
}

// ── Captures

type CaptureFlag = "none" | "pick" | "reject";
type ColorLabel = "none" | "red" | "yellow" | "green" | "blue" | "purple";
type MediaKind = "jpeg" | "heif" | "raw" | "jpegXL" | "video" | "other";
type CaptureState =
  | { kind: "announced" }
  | { kind: "downloading"; received: number; total: number | null }
  | { kind: "ready" }
  | { kind: "failed"; message: string };
interface ExposureSummary {
  aperture?: string | null;
  shutter?: string | null;
  iso?: string | null;
  compensation?: string | null;
  whiteBalance?: string | null;
}
interface CaptureItem {
  id: string;
  sessionId: string;
  sequence: number;
  filename: string;
  kind: MediaKind;
  bytes: number;
  width: number;
  height: number;
  capturedAt: ISODate;
  receivedAt: ISODate;
  rating: number;
  flag: CaptureFlag;
  colorLabel: ColorLabel;
  state: CaptureState;
  pairKey: string;
  source: TransportKind;
  lookId: string | null;
  exposure: ExposureSummary | null;
  cameraId: string | null;
  /** Bumped by the engine whenever the file or its preview changes; part of image URLs for cache busting. */
  revision: number;
}

// ── Sessions

type SessionStatus = "active" | "interrupted" | "ended";
type RoutingTarget = "photos" | "files" | "ftp" | "none";
interface RoutingRules {
  jpeg: RoutingTarget;
  raw: RoutingTarget;
  video: RoutingTarget;
  autoExportPicks: boolean;
  ftpDestinationId: string | null;
  liveFolderId: string | null;
}
interface ShootSession {
  id: string;
  name: string;
  createdAt: ISODate;
  endedAt: ISODate | null;
  status: SessionStatus;
  camera: CameraIdentity | null;
  transport: TransportKind | null;
  lastHost: string | null;
  destination: CaptureDestination;
  routing: RoutingRules;
  lookId: string | null;
  lookStrength: number;
  showNewestCapture: boolean;
  workflowTag: string | null;
  captureCount: number;
}
interface SessionCounts {
  total: number;
  ready: number;
  picks: number;
  rejects: number;
  rated: number;
  failed: number;
}
interface SessionSummary {
  session: ShootSession;
  counts: SessionCounts;
  /** Up to three newest ready captures, newest first (for the session card strip). */
  recent: CaptureItem[];
}
interface NewSessionDraft {
  name: string;
  workflowTag: string | null;
  destination: CaptureDestination;
  routing: RoutingRules;
  lookId: string | null;
  /** Template the form started from, recorded as a use. */
  templateId: string | null;
}
interface LookStack {
  lookId: string | null;
  strength: number;
}
interface SessionTemplate {
  id: string;
  name: string;
  symbol: string;
  destination: CaptureDestination;
  routing: RoutingRules;
  look: LookStack;
  showNewestCapture: boolean;
  autoExportPicks: boolean;
  tags: string[];
  namePattern: string;
  addToCollectionId: string | null;
  useCount: number;
  lastUsed: ISODate | null;
}

// ── Library

type CollectionKind = "manual" | "smart";
type DateRange =
  | { kind: "today" }
  | { kind: "last7Days" }
  | { kind: "last30Days" }
  | { kind: "between"; from: ISODate; to: ISODate };
type ExportDestinationKey = "photos" | "files" | "ftp" | "any" | "never";
/** Every field optional; absent / null means "any". */
interface CaptureFilter {
  minRating?: number | null;
  maxRating?: number | null;
  flags?: CaptureFlag[] | null;
  colors?: ColorLabel[] | null;
  kinds?: MediaKind[] | null;
  sessionIds?: string[] | null;
  cameraIds?: string[] | null;
  tagsAll?: string[] | null;
  tagsAny?: string[] | null;
  dateRange?: DateRange | null;
  text?: string | null;
  readyOnly?: boolean;
  hasLook?: boolean | null;
  exportedTo?: ExportDestinationKey | null;
}
interface Collection {
  id: string;
  name: string;
  kind: CollectionKind;
  rule: CaptureFilter | null;
  symbol: string;
  tint: ColorLabel;
  isPinned: boolean;
  sortOrder: number;
  createdAt: ISODate;
  updatedAt: ISODate;
  isBuiltIn: boolean;
}
type CaptureSort = "captureTimeAscending" | "captureTimeDescending" | "ratingDescending" | "filename" | "sessionThenTime";
type LibrarySource =
  | { kind: "collection"; id: string }
  | { kind: "session"; id: string }
  | { kind: "camera"; id: string };
interface LibrarySources {
  builtIns: Collection[];
  pinned: Collection[];
  manual: Collection[];
  smart: Collection[];
  sessions: ShootSession[];
  cameras: CameraIdentity[];
  /** Keyed by `sourceKey(source)`. */
  counts: Record<string, number>;
}
interface LibraryQuery {
  source: LibrarySource;
  filter: CaptureFilter;
  sort: CaptureSort;
  offset: number;
  limit: number;
}
interface LibraryPage {
  items: CaptureItem[];
  total: number;
}
interface ExportHistoryEntry {
  destination: string;
  at: ISODate;
  remoteId: string | null;
}
interface ExifSummary {
  make: string | null;
  model: string | null;
  lens: string | null;
  exposureLine: string | null;
  dateTimeOriginal: ISODate | null;
}
interface CaptureDetails {
  id: string;
  tags: string[];
  collectionIds: string[];
  exportHistory: ExportHistoryEntry[];
  exif: ExifSummary | null;
}
interface UndoState {
  undoTitle: string | null;
  redoTitle: string | null;
}
interface UndoResult {
  title: string;
  count: number;
}
type CatalogKind = "lightroom" | "captureOne";
interface CatalogChange {
  captureId: string;
  filename: string;
  rating: number | null;
  flag: CaptureFlag | null;
  label: ColorLabel | null;
  newKeywords: string[];
}
interface CatalogPreview {
  path: string;
  name: string;
  kind: CatalogKind;
  changes: CatalogChange[];
  unmatched: string[];
  openElsewhere: boolean;
}

// ── Looks

interface LookHint {
  warmth: number;
  contrast: number;
  saturation: number;
}
interface LookDescriptor {
  id: string;
  name: string;
  family: string;
  version: number;
  size: number;
  hint: LookHint | null;
}

// ── Export

type ExportDestination =
  | { kind: "photos" }
  | { kind: "files" }
  | { kind: "ftp"; destinationId: string }
  | { kind: "folder"; destinationId: string };
type RawOutput = "original" | "jpeg" | "heif" | "tiff16";
type FolderLayout = "flat" | "dated" | "bySession" | "captureOne" | "byRating" | "captureOneSessionRoot";
interface ExportOptions {
  applyLook: boolean;
  maxLongEdge: number | null;
  jpegQuality: number;
  includeRaw: boolean;
  namingPattern: string;
  layout: FolderLayout;
  embedMetadata: boolean;
  writeSidecars: boolean;
  writeManifest: boolean;
  rawOutput: RawOutput;
}
type ExportScope =
  | { kind: "all" }
  | { kind: "picks" }
  | { kind: "rated"; min: number }
  | { kind: "selected"; captureId: string }
  | { kind: "selection"; ids: string[] }
  | { kind: "collection"; collectionId: string };
interface ExportRequest {
  /** One session (shoot / session detail) or null (library: grouped into one job per session). */
  sessionId: string | null;
  /** Library context: the captures in view the scope is applied to; null = the whole session. */
  captureIds: string[] | null;
  scope: ExportScope;
  destination: ExportDestination;
  options: ExportOptions;
  /** Shoot screen: the live look stack; null = each session's own look. */
  look: LookStack | null;
}
interface ExportPlan {
  photoCount: number;
  rawCount: number;
  /** First three delivered relative paths. */
  previewPaths: string[];
}
type ExportItemState =
  | { kind: "pending" }
  | { kind: "uploading"; progress: number }
  | { kind: "done"; path: string | null }
  | { kind: "skipped"; reason: string }
  | { kind: "failed"; reason: string };
interface ExportJobItem {
  id: string;
  filename: string;
  kind: MediaKind;
  bytes: number;
  state: ExportItemState;
  deliveredPath: string;
  isCompanion: boolean;
}
type ExportJobStatus =
  | { kind: "queued" }
  | { kind: "running" }
  | { kind: "paused" }
  | { kind: "completed" }
  | { kind: "failed"; message: string };
interface ExportJob {
  id: string;
  sessionId: string;
  destination: ExportDestination;
  /** Human name of the destination ("Photos", "FTP · Studio NAS", "Capture One"). */
  destinationName: string;
  options: ExportOptions;
  look: LookStack;
  createdAt: ISODate;
  status: ExportJobStatus;
  items: ExportJobItem[];
  progress: number;
  attempts: number;
}
type FtpSecurity = "plain" | "explicitTLS" | "implicitTLS";
interface FtpDestination {
  id: string;
  name: string;
  host: string;
  port: number;
  username: string;
  security: FtpSecurity;
  passive: boolean;
  remoteDirectory: string;
}
type FolderKind = "plain" | "captureOneSession" | "lightroomAutoImport";
interface FolderDestination {
  id: string;
  name: string;
  path: string;
  kind: FolderKind;
}
interface ExportMemory {
  destination: ExportDestination;
  options: ExportOptions;
  /** Scope id: "all" | "picks" | "rated3" | "selected" | "selection" | "collection". */
  scope: string;
}

// ── Connect

interface UsbCandidate {
  id: string;
  name: string;
  vendorGuess: CameraVendor;
  usbVendorId: number;
  usbProductId: number;
  serialNumber: string | null;
}
interface UsbAuthorization {
  canSendPTP: boolean;
  isDenied: boolean;
  summary: string;
}
type DiscoveryMethod = "ssdp" | "bonjour" | "fujiUDP" | "ricohHTTP" | "httpProbe" | "manual";
interface DiscoveredCamera {
  id: string;
  name: string;
  vendor: CameraVendor | null;
  host: string;
  port: number;
  method: DiscoveryMethod;
  transport: TransportKind;
  lastSeen: ISODate;
  isControllable: boolean;
}
interface DiscoveryState {
  running: boolean;
  cameras: DiscoveredCamera[];
  /** Per-mechanism start errors, e.g. { ssdp: "Address in use" }. */
  errors: Record<string, string>;
}
interface KnownCamera {
  camera: CameraIdentity;
  host: string | null;
  lastSeen: ISODate;
}
type ConnectStep = "link" | "session" | "identify" | "prepare" | "ready";
type StepState = "pending" | "running" | "done" | "failed";
interface ConnectProgress {
  attemptId: string;
  transport: TransportKind;
  steps: { step: ConnectStep; title: string; state: StepState }[];
  failure: string | null;
}
interface NetworkInfo {
  /** Always null on macOS (no SSID access without location); the UI points at the Wi-Fi menu. */
  ssid: string | null;
  ssidAuthorization: "authorized" | "denied" | "notDetermined" | "unavailable";
  localAddresses: string[];
  /** Brand guessed from the SSID, when one is known. */
  cameraNetworkVendor: CameraVendor | null;
}
interface FtpReceivedFile {
  id: string;
  name: string;
  bytes: number;
  from: string;
  at: ISODate;
  durationSeconds: number;
}
interface FtpReceiverStatus {
  running: boolean;
  username: string;
  password: string;
  port: number;
  boundPort: number | null;
  addresses: string[];
  clients: number;
  lastError: string | null;
  received: FtpReceivedFile[];
}
type DiagnosticOutcome =
  | { kind: "pending" }
  | { kind: "running" }
  | { kind: "pass"; detail: string }
  | { kind: "warn"; detail: string }
  | { kind: "fail"; detail: string }
  | { kind: "skipped"; detail: string };
interface DiagnosticCheck {
  id: string;
  title: string;
  tip: string;
  outcome: DiagnosticOutcome;
}
interface DiagnosticReport {
  id: string;
  wired: boolean;
  verdict: string;
  checks: DiagnosticCheck[];
  finishedAt: ISODate | null;
  shareText: string;
}
interface PtpLogLine {
  at: ISODate;
  direction: "out" | "in" | "event" | "note";
  text: string;
}

// ── Shoot

type ShootStatus =
  | { kind: "idle" }
  | { kind: "connecting" }
  | { kind: "preparing" }
  | { kind: "ready" }
  | { kind: "capturing" }
  | { kind: "reconnecting" }
  | { kind: "disconnected"; reason: string }
  | { kind: "ended" };
type ReconnectStrategy =
  | { kind: "waitForUsbDevice"; serial: string | null }
  | { kind: "retryHost"; host: string; port: number; vendor: CameraVendor | null }
  | { kind: "retryRicoh"; host: string }
  | { kind: "retryHttp"; host: string; vendor: CameraVendor }
  | { kind: "nothingToDo" }
  | { kind: "startFresh" };
interface CameraMemoryOffer {
  look: LookStack;
  lookName: string;
  destination: CaptureDestination;
}
/** Snapshot of the one active shoot. */
interface ShootState {
  session: ShootSession;
  identity: CameraIdentity | null;
  status: ShootStatus;
  items: CaptureItem[];
  properties: PropertyDescriptor[];
  selectedItemId: string | null;
  downloadsInFlight: number;
  liveViewActive: boolean;
  look: LookStack;
  reconnect: ReconnectStrategy;
  /** "Use last time's look X?" banner, from the camera's workspace memory. */
  restoreOffer: CameraMemoryOffer | null;
  /** True for the built-in demo shoot (no camera). */
  isDemo: boolean;
}
type FocusResult = "focused" | "failed" | "unconfirmed";
interface LiveViewFrame {
  sequence: number;
  width: number | null;
  height: number | null;
  /** Resolved by the client: `tether://localhost/liveview/<sequence>.jpg` in Tauri, a data URL in the mock. */
  url: string;
}

// ── Settings / memory

interface AppSettings {
  hasOnboarded: boolean;
  ftpUsername: string;
  ftpPassword: string;
  ftpPort: number;
}
interface MetadataProfile {
  creator: string | null;
  copyright: string | null;
  captionTemplate: string | null;
  hierarchicalRoot: string | null;
  sessionAsKeyword: boolean;
  embedInJpeg: boolean;
  writeSidecarsForRaw: boolean;
  writeSidecarsForJpeg: boolean;
  readIncomingXmp: boolean;
}
interface ViewState {
  filter: CaptureFilter;
  sort: CaptureSort;
  columns: number;
  stackPairs: boolean;
}
interface Recents {
  tags: string[];
  collectionIds: string[];
}
type PermissionKind = "localNetwork" | "photos";
type PermissionState = "granted" | "denied" | "notDetermined";
interface AppInfo {
  version: string;
  build: string;
  platform: string;
  backend: "tauri" | "mock";
}
interface ToastMessage {
  id: string;
  text: string;
  symbol: string;
  action?: { title: string; command: string } | null;
}
type DialogKind = "files" | "folder" | "catalog" | "cube";
interface IpcError {
  code: string;
  message: string;
}
```

## 7. Shell notes for `app/src-tauri`

- Window: title "Open Tether", default 1280×820, **min size 800×600**
  (the UI lays out for ≥ 800 px; the shoot screen switches to side-by-side
  at ≥ 900 px), default decorations, background `#0A0B0E` so resizing
  never flashes white.
- Dev: `build.devUrl = "http://localhost:1420"`, `beforeDevCommand =
  "npm --prefix ui run dev"`, `frontendDist = "../ui/dist"`,
  `beforeBuildCommand = "npm --prefix ui run build"`.
- Capabilities: `core:default` (events), plus whatever the shell itself
  needs for dialogs if it implements `dialog_pick` with
  `tauri-plugin-dialog` on the Rust side (the UI does not import the
  plugin's JS; it only calls `dialog_pick`).
- Live view: decode nothing in Rust beyond `jpeg_payload()`; store the JPEG
  bytes under its sequence and emit `liveview:frame { sequence, width, height }`.
- Throttle high-frequency events: `capture:updated` progress and
  `export:job` to ~5/s per entity, `liveview:frame` to ~15/s,
  `library:changed` to ≤ 4/s.
- The engine owns all state (SQLite store, workspace memory, Keychain). The
  UI keeps only view state it can rebuild; on reload it calls `app_info`,
  `settings_get`, `sessions_list`, `looks_list`, `export_jobs`,
  `undo_state`, `shoot_state`, `last_source_get`, `library_sources`.
- Keyboard shortcuts are handled in the web view (the command catalogue
  from `ReviewEditor.swift` is ported in `ui/src/commands/catalogue.ts`).
  A native menu bar may mirror them later by emitting a `menu:command`
  event (not in this contract yet).

