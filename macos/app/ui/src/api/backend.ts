import type {
  AppInfo, AppSettings, CaptureDestination, CaptureDetails, CaptureFilter, CaptureFlag, CaptureItem, CatalogChange,
  CatalogPreview, Collection, ColorLabel, ConnectProgress, DiagnosticReport, DialogKind, DiscoveredCamera, DiscoveryState,
  ExportJob, ExportPlan, ExportRequest, FocusResult, FolderDestination, FolderKind, FtpDestination, FtpReceivedFile,
  FtpReceiverStatus, KnownCamera, LibraryPage, LibraryQuery, LibrarySources, LiveViewFrame, LookDescriptor, LookStack,
  MetadataProfile, NetworkInfo, NewSessionDraft, PermissionKind, PermissionState, PropertyDescriptor, PtpLogLine,
  PTPValue, Recents, RoutingRules, SessionSummary, SessionTemplate, ShootSession, ShootState, ShootStatus,
  TetherProperty, ToastMessage, UndoResult, UndoState, UsbAuthorization, UsbCandidate, ViewState, ExportMemory,
  CameraVendor, CameraIdentity,
} from "./types";

/** Which rendition of a capture an image URL points at. */
export type ImageVariant = "thumb" | "preview" | "original";

export interface ImageOptions {
  /** Render through this look (thumb / preview only). */
  look?: LookStack | null;
  /** Cache-busting revision (CaptureItem.revision). */
  revision?: number;
}

/**
 * Every command the UI calls. Method names map 1:1 to Tauri command names
 * (camelCase here → snake_case in Rust, e.g. `sessionsList` → `sessions_list`);
 * argument objects are passed as the invoke args. See docs/IPC.md.
 */
export interface Commands {
  // App
  appInfo(): Promise<AppInfo>;
  settingsGet(): Promise<AppSettings>;
  settingsUpdate(args: { patch: Partial<AppSettings> }): Promise<AppSettings>;
  permissionsStatus(): Promise<Record<PermissionKind, PermissionState>>;
  permissionsRequest(args: { kind: PermissionKind }): Promise<PermissionState>;
  metadataProfileGet(): Promise<MetadataProfile>;
  metadataProfileSet(args: { profile: MetadataProfile }): Promise<void>;
  xmpPreview(args: { captureId: string | null }): Promise<{ filename: string | null; packet: string | null }>;
  viewStateGet(args: { key: string }): Promise<ViewState | null>;
  viewStateSet(args: { key: string; state: ViewState }): Promise<void>;
  lastSourceGet(): Promise<string | null>;
  recentsGet(): Promise<Recents>;
  exportMemoryGet(): Promise<ExportMemory>;
  dialogPick(args: { kind: DialogKind; multiple: boolean }): Promise<string[]>;
  revealInFinder(args: { captureId?: string; path?: string }): Promise<void>;
  openWifiSettings(): Promise<void>;
  ptpLog(): Promise<PtpLogLine[]>;

  // Sessions
  sessionsList(): Promise<SessionSummary[]>;
  sessionGet(args: { id: string }): Promise<SessionSummary>;
  sessionCaptures(args: { id: string }): Promise<CaptureItem[]>;
  sessionCreate(args: { draft: NewSessionDraft }): Promise<ShootSession>;
  sessionRename(args: { id: string; name: string }): Promise<ShootSession>;
  sessionDelete(args: { id: string }): Promise<void>;
  sessionDismissInterrupted(args: { id: string }): Promise<void>;
  sessionResume(args: { id: string }): Promise<ShootState>;
  sessionManifest(args: { id: string }): Promise<{ jsonPath: string; csvPath: string }>;
  sessionDefaults(): Promise<NewSessionDraft & { namePattern: string }>;
  templatesList(): Promise<SessionTemplate[]>;
  templateSave(args: { template: SessionTemplate }): Promise<SessionTemplate>;
  templateDelete(args: { id: string }): Promise<void>;
  templateFromSession(args: { sessionId: string }): Promise<SessionTemplate>;
  templateSuggest(args: { cameraId: string | null }): Promise<string | null>;
  templateExpandName(args: { pattern: string; templateName: string; cameraName: string | null }): Promise<string>;

  // Connect: USB
  usbDevices(): Promise<UsbCandidate[]>;
  usbAuthorization(): Promise<UsbAuthorization>;
  usbRequestAuthorization(): Promise<UsbAuthorization>;
  usbConnect(args: { candidateId: string; sessionId: string | null }): Promise<ShootState>;
  // Connect: Wi-Fi
  discoveryStart(): Promise<DiscoveryState>;
  discoveryStop(): Promise<void>;
  discoveryAddManual(args: { host: string; port: number; vendor: CameraVendor | null }): Promise<DiscoveredCamera>;
  wifiConnect(args: { cameraId: string; sessionId: string | null }): Promise<ShootState>;
  networkInfo(): Promise<NetworkInfo>;
  knownCameras(): Promise<KnownCamera[]>;
  connectCancel(): Promise<void>;
  // Connect: FTP receiver
  ftpReceiverStatus(): Promise<FtpReceiverStatus>;
  ftpReceiverStart(): Promise<FtpReceiverStatus>;
  ftpReceiverStop(): Promise<FtpReceiverStatus>;
  ftpReceiverStartSession(args: { sessionId: string | null }): Promise<ShootState>;
  // Connect: demo, diagnostics
  demoStart(): Promise<ShootState>;
  diagnosticsRun(args: { wired: boolean; host: string | null; port: number | null }): Promise<DiagnosticReport>;

  // Shoot (the one active session)
  shootState(): Promise<ShootState | null>;
  shootCapture(args: { autofocus: boolean }): Promise<void>;
  shootSetProperty(args: { property: TetherProperty; raw: PTPValue }): Promise<void>;
  shootLiveViewStart(): Promise<void>;
  shootLiveViewStop(): Promise<void>;
  shootFocus(args: { x: number; y: number }): Promise<FocusResult>;
  shootFocusTrackStart(args: { x: number; y: number }): Promise<void>;
  shootFocusTrackStop(): Promise<void>;
  shootSelect(args: { captureId: string | null }): Promise<void>;
  shootSetFollowNewest(args: { on: boolean }): Promise<void>;
  shootSetLook(args: { look: LookStack }): Promise<void>;
  shootSetDestination(args: { destination: CaptureDestination }): Promise<void>;
  shootSetRouting(args: { routing: RoutingRules }): Promise<void>;
  shootRestoreOffer(args: { accept: boolean }): Promise<void>;
  shootImportFiles(args: { paths: string[] }): Promise<{ imported: number }>;
  shootDeleteCapture(args: { captureId: string }): Promise<void>;
  shootReconnect(): Promise<ShootState>;
  shootReconnectCancel(): Promise<void>;
  shootEnd(): Promise<void>;

  // Library
  librarySources(): Promise<LibrarySources>;
  libraryQuery(args: { query: LibraryQuery }): Promise<LibraryPage>;
  libraryPreviewCount(args: { filter: CaptureFilter }): Promise<number>;
  captureDetails(args: { id: string }): Promise<CaptureDetails>;
  tagsSuggest(args: { prefix: string }): Promise<string[]>;
  reviewRate(args: { ids: string[]; stars: number }): Promise<UndoState>;
  reviewFlag(args: { ids: string[]; flag: CaptureFlag }): Promise<UndoState>;
  reviewLabel(args: { ids: string[]; label: ColorLabel }): Promise<UndoState>;
  reviewAddTags(args: { ids: string[]; tags: string[] }): Promise<UndoState>;
  reviewRemoveTags(args: { ids: string[]; tags: string[] }): Promise<UndoState>;
  reviewUndo(): Promise<UndoResult | null>;
  reviewRedo(): Promise<UndoResult | null>;
  undoState(): Promise<UndoState>;
  collectionAddItems(args: { ids: string[]; collectionId: string }): Promise<UndoState>;
  collectionRemoveItems(args: { ids: string[]; collectionId: string }): Promise<UndoState>;
  collectionCreate(args: { name: string; ids: string[]; symbol: string; tint: ColorLabel }): Promise<Collection>;
  collectionSave(args: { collection: Collection }): Promise<Collection>;
  collectionDelete(args: { id: string }): Promise<void>;
  collectionTogglePin(args: { id: string }): Promise<void>;
  collectionMove(args: { id: string; toIndex: number }): Promise<void>;
  capturesDelete(args: { ids: string[] }): Promise<void>;
  libraryImport(args: { paths: string[]; sessionId: string | null }): Promise<{ imported: number }>;
  catalogRead(args: { path: string }): Promise<CatalogPreview>;
  catalogApply(args: { changes: CatalogChange[] }): Promise<{ applied: number }>;

  // Looks
  looksList(): Promise<LookDescriptor[]>;
  looksImportCube(args: { paths: string[] }): Promise<{ added: number }>;
  lookColorMatch(args: { referenceId: string; targetId: string; strength: number }): Promise<LookDescriptor>;

  // Export
  exportPlan(args: { request: ExportRequest }): Promise<ExportPlan>;
  exportEnqueue(args: { request: ExportRequest }): Promise<ExportJob[]>;
  exportAgain(args: { captureIds: string[] }): Promise<ExportJob[]>;
  exportJobs(args: { sessionId: string | null }): Promise<ExportJob[]>;
  exportPauseAll(): Promise<void>;
  exportResumeAll(): Promise<void>;
  exportRetry(args: { jobId: string }): Promise<void>;
  exportReveal(args: { jobId: string }): Promise<void>;
  ftpDestinationsList(): Promise<FtpDestination[]>;
  ftpDestinationSave(args: { destination: FtpDestination; password: string | null }): Promise<FtpDestination>;
  ftpDestinationDelete(args: { id: string }): Promise<void>;
  ftpDestinationTest(args: { destination: FtpDestination; password: string }): Promise<string>;
  ftpDestinationPassword(args: { id: string }): Promise<string | null>;
  folderDestinationsList(): Promise<FolderDestination[]>;
  folderDestinationAdd(args: { path: string }): Promise<FolderDestination>;
  folderDestinationSetKind(args: { id: string; kind: FolderKind }): Promise<FolderDestination>;
  folderDestinationDelete(args: { id: string }): Promise<void>;
}

/** Event name → payload. See docs/IPC.md "Events". */
export interface EventMap {
  "shoot:started": ShootState;
  "shoot:ended": { sessionId: string };
  "shoot:status": { status: ShootStatus };
  "shoot:session": ShootSession;
  "shoot:identity": CameraIdentity | null;
  "shoot:properties": PropertyDescriptor[];
  "shoot:selection": { captureId: string | null };
  "shoot:liveview": { active: boolean };
  "shoot:look": LookStack;
  "shoot:downloads": { inFlight: number };
  "capture:added": CaptureItem;
  "capture:updated": CaptureItem;
  "capture:removed": { id: string; sessionId: string };
  "captures:changed": CaptureItem[];
  "liveview:frame": LiveViewFrame;
  "connect:progress": ConnectProgress;
  "usb:devices": UsbCandidate[];
  "discovery:cameras": DiscoveredCamera[];
  "ftp:status": FtpReceiverStatus;
  "ftp:file": FtpReceivedFile;
  "export:job": ExportJob;
  "export:finished": ExportJob;
  "diagnostics:update": DiagnosticReport;
  "undo:state": UndoState;
  "library:changed": { reason: string };
  "sessions:changed": { reason: string };
  "looks:changed": LookDescriptor[];
  "toast": ToastMessage;
}

export type EventName = keyof EventMap;
export type Unlisten = () => void;

export interface Backend extends Commands {
  readonly kind: "tauri" | "mock";
  on<E extends EventName>(event: E, handler: (payload: EventMap[E]) => void): Unlisten;
  /** URL for a capture rendition; usable as an <img src>. */
  imageUrl(capture: Pick<CaptureItem, "id" | "revision">, variant: ImageVariant, opts?: ImageOptions): string;
}
