// Every entity that crosses the IPC boundary. Field names are camelCase
// (serde `rename_all = "camelCase"`), enum values are the Swift raw values,
// dates are RFC 3339 strings. See docs/IPC.md for the contract.

export type ISODate = string;

// MARK: Camera

export type CameraVendor =
  | "canon" | "nikon" | "sony" | "fujifilm" | "ricoh" | "leica" | "olympus" | "panasonic"
  | "hasselblad" | "generic" | "pentax" | "sigma" | "samsung" | "gopro" | "osc";

export const VENDOR_NAMES: Record<CameraVendor, string> = {
  canon: "Canon",
  nikon: "Nikon",
  sony: "Sony",
  fujifilm: "Fujifilm",
  ricoh: "Ricoh",
  leica: "Leica",
  olympus: "OM System / Olympus",
  panasonic: "Panasonic Lumix",
  hasselblad: "Hasselblad",
  pentax: "Pentax",
  sigma: "Sigma",
  samsung: "Samsung NX",
  gopro: "GoPro",
  osc: "360° camera (Theta, Insta360…)",
  generic: "Generic PTP camera",
};

export const WIRELESS_VENDORS: CameraVendor[] = ["canon", "nikon", "sony", "fujifilm", "ricoh", "gopro", "osc"];

export type TransportKind = "usb" | "ptpip" | "ricohHTTP" | "ftpPush" | "http";

export const TRANSPORT_NAMES: Record<TransportKind, string> = {
  usb: "USB-C",
  ptpip: "Wi-Fi (PTP/IP)",
  ricohHTTP: "Wi-Fi (Ricoh)",
  ftpPush: "FTP push",
  http: "Wi-Fi",
};

/** Bit mask, same bits as iOS `CameraCapabilities` and Rust `tether_types::CameraCapabilities`. */
export const Cap = {
  remoteCapture: 1 << 0,
  sdramCapture: 1 << 1,
  cardCapture: 1 << 2,
  liveView: 1 << 3,
  propertyControl: 1 << 4,
  partialTransfer: 1 << 5,
  rating: 1 << 6,
  reducedImage: 1 << 7,
  wireless: 1 << 8,
  autofocus: 1 << 9,
  bulbCapture: 1 << 10,
  thumbnails: 1 << 11,
  eventPush: 1 << 12,
  importOnly: 1 << 13,
  touchAutofocus: 1 << 14,
} as const;

export function hasCap(mask: number, cap: number): boolean {
  return (mask & cap) === cap;
}

export function capabilitySummary(mask: number): string[] {
  const out: string[] = [];
  if (hasCap(mask, Cap.remoteCapture)) out.push("Remote capture");
  if (hasCap(mask, Cap.sdramCapture)) out.push("Capture without card");
  if (hasCap(mask, Cap.liveView)) out.push("Live view");
  if (hasCap(mask, Cap.propertyControl)) out.push("Exposure control");
  if (hasCap(mask, Cap.autofocus)) out.push("Autofocus");
  if (hasCap(mask, Cap.partialTransfer)) out.push("Resumable transfer");
  if (hasCap(mask, Cap.rating)) out.push("Rating sync");
  if (hasCap(mask, Cap.importOnly)) out.push("Import only");
  return out;
}

export interface CameraIdentity {
  id: string;
  vendor: CameraVendor;
  manufacturer: string;
  model: string;
  serialNumber: string;
  firmware: string;
  transport: TransportKind;
  capabilities: number;
}

export function cameraDisplayName(c: CameraIdentity): string {
  return c.model || VENDOR_NAMES[c.vendor];
}

export type CaptureDestination = "card" | "host" | "both";

export const DESTINATION_NAMES: Record<CaptureDestination, string> = {
  card: "Card only",
  host: "Mac only (no card)",
  both: "Card + Mac",
};

export type TetherProperty =
  | "aperture" | "shutterSpeed" | "iso" | "exposureCompensation" | "whiteBalance" | "colorTemperature"
  | "exposureProgram" | "driveMode" | "meteringMode" | "focusMode" | "imageQuality" | "imageSize"
  | "captureDestination" | "batteryLevel" | "liveViewEnabled" | "flashMode" | "pictureStyle"
  | "storageFreeImages" | "lensName" | "shutterCount";

export const PROPERTY_NAMES: Record<TetherProperty, string> = {
  aperture: "Aperture",
  shutterSpeed: "Shutter",
  iso: "ISO",
  exposureCompensation: "Exp. comp.",
  whiteBalance: "White balance",
  colorTemperature: "Color temp.",
  exposureProgram: "Mode",
  driveMode: "Drive",
  meteringMode: "Metering",
  focusMode: "Focus",
  imageQuality: "Quality",
  imageSize: "Size",
  captureDestination: "Destination",
  batteryLevel: "Battery",
  liveViewEnabled: "Live view",
  flashMode: "Flash",
  pictureStyle: "Picture style",
  storageFreeImages: "Shots left",
  lensName: "Lens",
  shutterCount: "Shutter count",
};

/** The settings bar on the shoot screen shows these, in this order. */
export const EXPOSURE_BAR: TetherProperty[] = ["shutterSpeed", "aperture", "iso", "exposureCompensation", "whiteBalance"];

/** A PTP value as JSON: integers stay numbers, strings stay strings. Opaque to the UI. */
export type PTPValue = number | string;

export interface PropertyChoice {
  raw: PTPValue;
  display: string;
}

export type PropertyForm =
  | { kind: "choices"; choices: PropertyChoice[] }
  | { kind: "range"; min: number; max: number; step: number }
  | { kind: "other" };

export interface PropertyDescriptor {
  property: TetherProperty;
  raw: PTPValue;
  display: string;
  isWritable: boolean;
  form: PropertyForm;
}

export function propertyChoices(d: PropertyDescriptor | undefined): PropertyChoice[] {
  return d && d.form.kind === "choices" ? d.form.choices : [];
}

// MARK: Captures

export type CaptureFlag = "none" | "pick" | "reject";
export type ColorLabel = "none" | "red" | "yellow" | "green" | "blue" | "purple";
export const COLOR_LABELS: ColorLabel[] = ["red", "yellow", "green", "blue", "purple"];
export type MediaKind = "jpeg" | "heif" | "raw" | "jpegXL" | "video" | "other";

export type CaptureState =
  | { kind: "announced" }
  | { kind: "downloading"; received: number; total: number | null }
  | { kind: "ready" }
  | { kind: "failed"; message: string };

export interface ExposureSummary {
  aperture?: string | null;
  shutter?: string | null;
  iso?: string | null;
  compensation?: string | null;
  whiteBalance?: string | null;
}

export interface CaptureItem {
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

export const isReady = (c: CaptureItem) => c.state.kind === "ready";
export const isFailed = (c: CaptureItem) => c.state.kind === "failed";
export function downloadProgress(c: CaptureItem): number | null {
  if (c.state.kind === "downloading" && c.state.total) return c.state.received / c.state.total;
  return null;
}

export function exposureLine(e: ExposureSummary | null | undefined): string {
  if (!e) return "";
  return [e.shutter, e.aperture, e.iso ? `ISO ${e.iso}` : null, e.compensation && e.compensation !== "0" ? `${e.compensation} EV` : null]
    .filter(Boolean)
    .join("  ");
}

// MARK: Sessions

export type SessionStatus = "active" | "interrupted" | "ended";
export type RoutingTarget = "photos" | "files" | "ftp" | "none";

export const ROUTING_NAMES: Record<RoutingTarget, string> = {
  photos: "Photos",
  files: "Files (Pictures › Open Tether)",
  ftp: "FTP server",
  none: "Keep in session only",
};

export interface RoutingRules {
  jpeg: RoutingTarget;
  raw: RoutingTarget;
  video: RoutingTarget;
  autoExportPicks: boolean;
  ftpDestinationId: string | null;
  liveFolderId: string | null;
}

export interface ShootSession {
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

export interface SessionCounts {
  total: number;
  ready: number;
  picks: number;
  rejects: number;
  rated: number;
  failed: number;
}

export interface SessionSummary {
  session: ShootSession;
  counts: SessionCounts;
  /** Up to three newest ready captures, newest first (for the session card strip). */
  recent: CaptureItem[];
}

export interface NewSessionDraft {
  name: string;
  workflowTag: string | null;
  destination: CaptureDestination;
  routing: RoutingRules;
  lookId: string | null;
  /** Template the form started from, recorded as a use. */
  templateId: string | null;
}

export interface LookStack {
  lookId: string | null;
  strength: number;
}

export interface SessionTemplate {
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

// MARK: Library

export type CollectionKind = "manual" | "smart";

export type DateRange =
  | { kind: "today" }
  | { kind: "last7Days" }
  | { kind: "last30Days" }
  | { kind: "between"; from: ISODate; to: ISODate };

export type ExportDestinationKey = "photos" | "files" | "ftp" | "any" | "never";

/** Every field optional; absent / null means "any". */
export interface CaptureFilter {
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

export interface Collection {
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

export type CaptureSort = "captureTimeAscending" | "captureTimeDescending" | "ratingDescending" | "filename" | "sessionThenTime";

export const SORT_NAMES: Record<CaptureSort, string> = {
  captureTimeAscending: "Oldest first",
  captureTimeDescending: "Newest first",
  ratingDescending: "Rating",
  filename: "Filename",
  sessionThenTime: "Session",
};

export type LibrarySource =
  | { kind: "collection"; id: string }
  | { kind: "session"; id: string }
  | { kind: "camera"; id: string };

export function sourceKey(s: LibrarySource): string {
  return `${s.kind}:${s.id}`;
}

export interface LibrarySources {
  builtIns: Collection[];
  pinned: Collection[];
  manual: Collection[];
  smart: Collection[];
  sessions: ShootSession[];
  cameras: CameraIdentity[];
  /** Keyed by `sourceKey(source)`. */
  counts: Record<string, number>;
}

export interface LibraryQuery {
  source: LibrarySource;
  filter: CaptureFilter;
  sort: CaptureSort;
  offset: number;
  limit: number;
}

export interface LibraryPage {
  items: CaptureItem[];
  total: number;
}

export interface ExportHistoryEntry {
  destination: string;
  at: ISODate;
  remoteId: string | null;
}

export interface ExifSummary {
  make: string | null;
  model: string | null;
  lens: string | null;
  exposureLine: string | null;
  dateTimeOriginal: ISODate | null;
}

export interface CaptureDetails {
  id: string;
  tags: string[];
  collectionIds: string[];
  exportHistory: ExportHistoryEntry[];
  exif: ExifSummary | null;
}

export interface UndoState {
  undoTitle: string | null;
  redoTitle: string | null;
}

export interface UndoResult {
  title: string;
  count: number;
}

export type CatalogKind = "lightroom" | "captureOne";

export interface CatalogChange {
  captureId: string;
  filename: string;
  rating: number | null;
  flag: CaptureFlag | null;
  label: ColorLabel | null;
  newKeywords: string[];
}

export interface CatalogPreview {
  path: string;
  name: string;
  kind: CatalogKind;
  changes: CatalogChange[];
  unmatched: string[];
  openElsewhere: boolean;
}

// MARK: Looks

export interface LookHint {
  warmth: number;
  contrast: number;
  saturation: number;
}

export interface LookDescriptor {
  id: string;
  name: string;
  family: string;
  version: number;
  size: number;
  hint: LookHint | null;
}

// MARK: Export

export type ExportDestination =
  | { kind: "photos" }
  | { kind: "files" }
  | { kind: "ftp"; destinationId: string }
  | { kind: "folder"; destinationId: string };

export function destinationKey(d: ExportDestination): string {
  return d.kind === "ftp" || d.kind === "folder" ? `${d.kind}:${d.destinationId}` : d.kind;
}

export function destinationLabel(d: ExportDestination): string {
  switch (d.kind) {
    case "photos": return "Photos";
    case "files": return "Files";
    case "ftp": return "FTP";
    case "folder": return "Folder";
  }
}

export type RawOutput = "original" | "jpeg" | "heif" | "tiff16";
export const RAW_OUTPUT_NAMES: Record<RawOutput, string> = {
  original: "Original RAW",
  jpeg: "JPEG",
  heif: "HEIF",
  tiff16: "16-bit TIFF",
};

export type FolderLayout = "flat" | "dated" | "bySession" | "captureOne" | "byRating" | "captureOneSessionRoot";
export const FOLDER_LAYOUT_NAMES: Record<FolderLayout, string> = {
  flat: "Flat",
  dated: "By date (yyyy/yyyy-MM-dd)",
  bySession: "By session",
  captureOne: "Capture One session",
  byRating: "By rating",
  captureOneSessionRoot: "Into a Capture One session",
};

export const NAMING_PRESETS = ["{orig}", "{session}_{seq:4}", "{date}_{session}_{seq:4}", "{client}_{date}_{seq:3}"];

export interface ExportOptions {
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

export type ExportScope =
  | { kind: "all" }
  | { kind: "picks" }
  | { kind: "rated"; min: number }
  | { kind: "selected"; captureId: string }
  | { kind: "selection"; ids: string[] }
  | { kind: "collection"; collectionId: string };

export interface ExportRequest {
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

export interface ExportPlan {
  photoCount: number;
  rawCount: number;
  /** First three delivered relative paths. */
  previewPaths: string[];
}

export type ExportItemState =
  | { kind: "pending" }
  | { kind: "uploading"; progress: number }
  | { kind: "done"; path: string | null }
  | { kind: "skipped"; reason: string }
  | { kind: "failed"; reason: string };

export interface ExportJobItem {
  id: string;
  filename: string;
  kind: MediaKind;
  bytes: number;
  state: ExportItemState;
  deliveredPath: string;
  isCompanion: boolean;
}

export type ExportJobStatus =
  | { kind: "queued" }
  | { kind: "running" }
  | { kind: "paused" }
  | { kind: "completed" }
  | { kind: "failed"; message: string };

export interface ExportJob {
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

export type FtpSecurity = "plain" | "explicitTLS" | "implicitTLS";

export interface FtpDestination {
  id: string;
  name: string;
  host: string;
  port: number;
  username: string;
  security: FtpSecurity;
  passive: boolean;
  remoteDirectory: string;
}

export type FolderKind = "plain" | "captureOneSession" | "lightroomAutoImport";

export interface FolderDestination {
  id: string;
  name: string;
  path: string;
  kind: FolderKind;
}

export interface ExportMemory {
  destination: ExportDestination;
  options: ExportOptions;
  /** Scope id: "all" | "picks" | "rated3" | "selected" | "selection" | "collection". */
  scope: string;
}

// MARK: Connect

export interface UsbCandidate {
  id: string;
  name: string;
  vendorGuess: CameraVendor;
  usbVendorId: number;
  usbProductId: number;
  serialNumber: string | null;
}

export interface UsbAuthorization {
  canSendPTP: boolean;
  isDenied: boolean;
  summary: string;
}

export type DiscoveryMethod = "ssdp" | "bonjour" | "fujiUDP" | "ricohHTTP" | "httpProbe" | "manual";

export interface DiscoveredCamera {
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

export interface DiscoveryState {
  running: boolean;
  cameras: DiscoveredCamera[];
  /** Per-mechanism start errors, e.g. { ssdp: "Address in use" }. */
  errors: Record<string, string>;
}

export interface KnownCamera {
  camera: CameraIdentity;
  host: string | null;
  lastSeen: ISODate;
}

export type ConnectStep = "link" | "session" | "identify" | "prepare" | "ready";
export type StepState = "pending" | "running" | "done" | "failed";

export interface ConnectProgress {
  attemptId: string;
  transport: TransportKind;
  steps: { step: ConnectStep; title: string; state: StepState }[];
  failure: string | null;
}

export interface NetworkInfo {
  /** Always null on macOS (no SSID access without location); the UI points at the Wi-Fi menu. */
  ssid: string | null;
  ssidAuthorization: "authorized" | "denied" | "notDetermined" | "unavailable";
  localAddresses: string[];
  /** Brand guessed from the SSID, when one is known. */
  cameraNetworkVendor: CameraVendor | null;
}

export interface FtpReceivedFile {
  id: string;
  name: string;
  bytes: number;
  from: string;
  at: ISODate;
  durationSeconds: number;
}

export interface FtpReceiverStatus {
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

export type DiagnosticOutcome =
  | { kind: "pending" }
  | { kind: "running" }
  | { kind: "pass"; detail: string }
  | { kind: "warn"; detail: string }
  | { kind: "fail"; detail: string }
  | { kind: "skipped"; detail: string };

export interface DiagnosticCheck {
  id: string;
  title: string;
  tip: string;
  outcome: DiagnosticOutcome;
}

export interface DiagnosticReport {
  id: string;
  wired: boolean;
  verdict: string;
  checks: DiagnosticCheck[];
  finishedAt: ISODate | null;
  shareText: string;
}

export interface PtpLogLine {
  at: ISODate;
  direction: "out" | "in" | "event" | "note";
  text: string;
}

// MARK: Shoot

export type ShootStatus =
  | { kind: "idle" }
  | { kind: "connecting" }
  | { kind: "preparing" }
  | { kind: "ready" }
  | { kind: "capturing" }
  | { kind: "reconnecting" }
  | { kind: "disconnected"; reason: string }
  | { kind: "ended" };

export function isLiveStatus(s: ShootStatus): boolean {
  return s.kind === "ready" || s.kind === "capturing";
}

export function statusText(s: ShootStatus): string {
  switch (s.kind) {
    case "idle": return "Idle";
    case "connecting": return "Connecting";
    case "preparing": return "Preparing";
    case "ready": return "Ready";
    case "capturing": return "Capturing";
    case "reconnecting": return "Reconnecting";
    case "disconnected": return s.reason;
    case "ended": return "Ended";
  }
}

export type ReconnectStrategy =
  | { kind: "waitForUsbDevice"; serial: string | null }
  | { kind: "retryHost"; host: string; port: number; vendor: CameraVendor | null }
  | { kind: "retryRicoh"; host: string }
  | { kind: "retryHttp"; host: string; vendor: CameraVendor }
  | { kind: "nothingToDo" }
  | { kind: "startFresh" };

export interface CameraMemoryOffer {
  look: LookStack;
  lookName: string;
  destination: CaptureDestination;
}

/** Snapshot of the one active shoot. */
export interface ShootState {
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

export type FocusResult = "focused" | "failed" | "unconfirmed";

export interface LiveViewFrame {
  sequence: number;
  width: number | null;
  height: number | null;
  /** Resolved by the client: `tether://localhost/liveview/<sequence>.jpg` in Tauri, a data URL in the mock. */
  url: string;
}

// MARK: Settings / memory

export interface AppSettings {
  hasOnboarded: boolean;
  ftpUsername: string;
  ftpPassword: string;
  ftpPort: number;
}

export interface MetadataProfile {
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

export interface ViewState {
  filter: CaptureFilter;
  sort: CaptureSort;
  columns: number;
  stackPairs: boolean;
}

export interface Recents {
  tags: string[];
  collectionIds: string[];
}

export type PermissionKind = "localNetwork" | "photos";
export type PermissionState = "granted" | "denied" | "notDetermined";

export interface AppInfo {
  version: string;
  build: string;
  platform: string;
  backend: "tauri" | "mock";
}

export interface ToastMessage {
  id: string;
  text: string;
  symbol: string;
  action?: { title: string; command: string } | null;
}

export type DialogKind = "files" | "folder" | "catalog" | "cube";

export interface IpcError {
  code: string;
  message: string;
}
