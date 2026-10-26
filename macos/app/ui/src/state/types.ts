import type {
  CameraVendor, CaptureFilter, CaptureItem, CaptureSort, Collection, ExportScope, FtpDestination, LibrarySource, LookStack,
  SessionTemplate, ShootSession, TetherProperty,
} from "../api";

/** Pushed screens inside the Connect, Sessions and Settings stacks. */
export type Route =
  | { kind: "connectHub" }
  | { kind: "usb" }
  | { kind: "wifi" }
  | { kind: "ftpReceiver" }
  | { kind: "brandGuides" }
  | { kind: "brandGuide"; vendor: CameraVendor }
  | { kind: "diagnostics"; wired: boolean }
  | { kind: "sessionsHome" }
  | { kind: "sessionDetail"; id: string }
  | { kind: "exportProgress"; sessionId: string | null }
  | { kind: "ftpDestinations" }
  | { kind: "folderDestinations" }
  | { kind: "settings" }
  | { kind: "metadata" }
  | { kind: "testedCameras" }
  | { kind: "ptpLog" }
  | { kind: "privacy" }
  | { kind: "about" };

export type StackName = "connect" | "sessions" | "settings";

export type Pane = "connect" | "sessions" | "library";

/** Where the export sheet was opened from, and what it can cover. */
export interface ExportContext {
  /** One session (shoot, session detail) or null for the library (may span sessions). */
  sessionId: string | null;
  /** Library: the captures in view; null = whole session. */
  captureIds: string[] | null;
  selectionIds: string[];
  /** Shoot: the displayed frame for "Selected". */
  selectedId: string | null;
  collection: Collection | null;
  /** Live look from the shoot; null = each session's own. */
  look: LookStack | null;
  title?: string;
  initialScope?: ExportScope["kind"];
}

/** Which list a loupe / compare / client review walks through. */
export type Origin = "shoot" | "library" | "session";

export type Modal =
  | { kind: "palette" }
  | { kind: "settings" }
  | { kind: "newSession"; onCreated?: (s: ShootSession) => void }
  | { kind: "export"; ctx: ExportContext }
  | { kind: "exportProgress"; sessionId: string | null }
  | { kind: "tags"; ids: string[] }
  | { kind: "collectionPicker"; ids: string[] }
  | { kind: "collectionEditor"; draft: Collection; pendingIds?: string[] }
  | { kind: "catalogSync"; path: string }
  | { kind: "templateEditor"; template: SessionTemplate; isNew: boolean }
  | { kind: "manualIP" }
  | { kind: "ftpDestinationEditor"; destination: FtpDestination | null }
  | { kind: "confirm"; title: string; message: string; confirmTitle: string; destructive?: boolean; cancelTitle?: string; onConfirm: () => void }
  | { kind: "rename"; title: string; value: string; onSave: (value: string) => void }
  | { kind: "looks" }
  | { kind: "colorMatch"; targetId?: string | null }
  | { kind: "compare"; origin: Origin; ids: string[] }
  | { kind: "property"; property: TetherProperty }
  | { kind: "reconnect" }
  | { kind: "diagnosticsSheet"; wired: boolean }
  | { kind: "loupe"; origin: Origin }
  | { kind: "clientReview"; origin: Origin };

export type ModalKind = Modal["kind"];

export interface SelectionState {
  ids: string[];
  anchor: string | null;
}

export interface LibraryState {
  source: LibrarySource;
  filter: CaptureFilter;
  search: string;
  sort: CaptureSort;
  columns: number;
  stackPairs: boolean;
  expanded: string[];
  items: CaptureItem[];
  total: number;
  loading: boolean;
  selection: SelectionState;
  focusedId: string | null;
  inspectorOpen: boolean;
  loupeId: string | null;
  scrollToId: string | null;
}

export type FocusIndicator = "focusing" | "focused" | "failed" | "unconfirmed" | "tracking";
