// In-browser stand-in for the Rust engine: a seeded library, a demo camera,
// discovery, an FTP receiver, an export queue and the undoable review editor.
// Selected automatically when the page is not running inside Tauri.

import type { Backend, EventMap, EventName, ImageOptions, ImageVariant, Unlisten } from "../backend";
import type {
  AppSettings, CameraIdentity, CameraVendor, CaptureDestination, CaptureFilter, CaptureFlag, CaptureItem, CaptureSort, CatalogChange,
  Collection, ColorLabel, ConnectProgress, ConnectStep, DiagnosticCheck, DiagnosticReport, DiscoveredCamera, ExportHistoryEntry, ExportJob,
  ExportMemory, ExportOptions, ExportPlan, ExportRequest, ExportScope, FolderDestination, FtpReceiverStatus, KnownCamera,
  LibrarySource, LookStack, MetadataProfile, PermissionKind, PermissionState, PropertyChoice,
  PropertyDescriptor, PtpLogLine, PTPValue, ReconnectStrategy, SessionCounts, SessionSummary, SessionTemplate, ShootSession, ShootState,
  TetherProperty, ToastMessage, TransportKind, UndoState, UsbCandidate, ViewState, Recents, MediaKind,
} from "../types";
import { Cap, VENDOR_NAMES, cameraDisplayName, hasCap, sourceKey, WIRELESS_VENDORS } from "../types";
import type { LookRecipe, Scene, SceneSpec } from "./images";
import { renderFrame, renderLiveFrame, rng } from "./images";
import {
  CAMERAS, DAY, LOOK_RECIPES, buildCollections, buildFolderDestinations, buildFtpDestinations, buildLibrary, buildTemplates,
  defaultRouting, exposureFor, filenameFor, iso, lookDescriptor, uid,
} from "./seed";
import { normalizeTag } from "../../lib/filter";

const wait = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
const clone = <T,>(v: T): T => (v === undefined ? v : (JSON.parse(JSON.stringify(v)) as T));

class MockError extends Error {
  code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

// MARK: Camera properties

const SHUTTERS = ["30\"", "15\"", "8\"", "4\"", "2\"", "1\"", "1/2", "1/4", "1/8", "1/15", "1/30", "1/60", "1/125", "1/250", "1/500", "1/1000", "1/2000", "1/4000", "1/8000"];
const shutterSeconds = (s: string) => (s.endsWith("\"") ? parseFloat(s) : 1 / parseFloat(s.split("/")[1]));
const APERTURES = [1.8, 2, 2.8, 4, 5.6, 8, 11, 16, 22];
const ISOS = [100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600];
const ECS = Array.from({ length: 19 }, (_, i) => Math.round((i - 9) * 333.33));
const WBS: [string, number][] = [["Auto", 2], ["Daylight", 4], ["Shade", 32784], ["Cloudy", 32785], ["Tungsten", 6], ["Fluorescent", 5], ["Flash", 7], ["5600K", 32786]];
const fmtAperture = (f: number) => (Number.isInteger(f) ? `ƒ/${f}` : `ƒ/${f.toFixed(1)}`);
const fmtEC = (t: number) => {
  const ev = t / 1000;
  if (Math.abs(ev) < 0.01) return "0";
  return (ev > 0 ? "+" : "") + ev.toFixed(1).replace(".0", "");
};

function choices<T>(list: T[], raw: (v: T) => PTPValue, display: (v: T) => string): PropertyChoice[] {
  return list.map((v) => ({ raw: raw(v), display: display(v) }));
}

function initialProperties(writable: boolean): PropertyDescriptor[] {
  const desc = (property: TetherProperty, cs: PropertyChoice[], current: PTPValue, w = writable): PropertyDescriptor => ({
    property, raw: current, display: cs.find((c) => c.raw === current)?.display ?? String(current), isWritable: w, form: { kind: "choices", choices: cs },
  });
  return [
    desc("shutterSpeed", choices(SHUTTERS, (s) => Math.round(shutterSeconds(s) * 10000), (s) => s), Math.round((1 / 125) * 10000)),
    desc("aperture", choices(APERTURES, (f) => Math.round(f * 100), fmtAperture), 560),
    desc("iso", choices(ISOS, (v) => v, (v) => String(v)), 400),
    desc("exposureCompensation", choices(ECS, (v) => v, fmtEC), 0),
    desc("whiteBalance", choices(WBS, (w) => w[1], (w) => w[0]), 2),
    desc("captureDestination", choices<CaptureDestination>(["card", "host", "both"], (d) => d, (d) => ({ card: "Card", host: "Mac", both: "Card + Mac" })[d]), "both"),
    { property: "batteryLevel", raw: 82, display: "82%", isWritable: false, form: { kind: "other" } },
    { property: "lensName", raw: "RF24-70mm F2.8 L IS USM", display: "RF24-70mm F2.8 L IS USM", isWritable: false, form: { kind: "other" } },
  ];
}

function evFromProperties(props: PropertyDescriptor[]): number {
  const get = (p: TetherProperty) => props.find((d) => d.property === p)?.raw;
  const shutter = Number(get("shutterSpeed") ?? 80) / 10000;
  const f = Number(get("aperture") ?? 560) / 100;
  const isoV = Number(get("iso") ?? 400);
  const ec = Number(get("exposureCompensation") ?? 0) / 1000;
  const ev = Math.log2(shutter / (1 / 125)) + Math.log2(isoV / 400) - 2 * Math.log2(f / 5.6);
  return Math.max(-4, Math.min(3, ev * 0.6 + ec * 0.4));
}

function exposureSummary(props: PropertyDescriptor[]) {
  const d = (p: TetherProperty) => props.find((x) => x.property === p)?.display ?? null;
  return { shutter: d("shutterSpeed"), aperture: d("aperture"), iso: d("iso"), compensation: d("exposureCompensation"), whiteBalance: d("whiteBalance") };
}

// MARK: Filter evaluation (the Rust store does this in SQL)

interface MatchContext {
  tags: (id: string) => Set<string>;
  sessionName: (id: string) => string;
  exported: (id: string) => ExportHistoryEntry[];
  now: number;
}

function matches(f: CaptureFilter, c: CaptureItem, ctx: MatchContext): boolean {
  if ((f.readyOnly ?? true) && c.state.kind !== "ready") return false;
  if (f.minRating != null && c.rating < f.minRating) return false;
  if (f.maxRating != null && c.rating > f.maxRating) return false;
  if (f.flags?.length && !f.flags.includes(c.flag)) return false;
  if (f.colors?.length && !f.colors.includes(c.colorLabel)) return false;
  if (f.kinds?.length && !f.kinds.includes(c.kind)) return false;
  if (f.sessionIds?.length && !f.sessionIds.includes(c.sessionId)) return false;
  if (f.cameraIds?.length && !(c.cameraId && f.cameraIds.includes(c.cameraId))) return false;
  if (f.tagsAll?.length) {
    const t = ctx.tags(c.id);
    if (!f.tagsAll.every((x) => t.has(x))) return false;
  }
  if (f.tagsAny?.length) {
    const t = ctx.tags(c.id);
    if (!f.tagsAny.some((x) => t.has(x))) return false;
  }
  if (f.dateRange) {
    const at = new Date(c.receivedAt).getTime();
    const start = new Date(ctx.now);
    start.setHours(0, 0, 0, 0);
    switch (f.dateRange.kind) {
      case "today": if (at < start.getTime()) return false; break;
      case "last7Days": if (at < ctx.now - 7 * DAY) return false; break;
      case "last30Days": if (at < ctx.now - 30 * DAY) return false; break;
      case "between": if (at < new Date(f.dateRange.from).getTime() || at > new Date(f.dateRange.to).getTime()) return false; break;
    }
  }
  const text = (f.text ?? "").trim().toLowerCase();
  if (text) {
    const hit = c.filename.toLowerCase().includes(text) || ctx.sessionName(c.sessionId).toLowerCase().includes(text)
      || [...ctx.tags(c.id)].some((t) => t.includes(text));
    if (!hit) return false;
  }
  if (f.hasLook != null && (c.lookId != null) !== f.hasLook) return false;
  if (f.exportedTo) {
    const h = ctx.exported(c.id);
    if (f.exportedTo === "never" && h.length > 0) return false;
    if (f.exportedTo === "any" && h.length === 0) return false;
    if (f.exportedTo !== "never" && f.exportedTo !== "any" && !h.some((e) => e.destination === f.exportedTo)) return false;
  }
  return true;
}

function sortCaptures(list: CaptureItem[], sort: CaptureSort): CaptureItem[] {
  const by = [...list];
  switch (sort) {
    case "captureTimeAscending": return by.sort((a, b) => a.receivedAt.localeCompare(b.receivedAt) || a.sequence - b.sequence || a.kind.localeCompare(b.kind));
    case "captureTimeDescending": return by.sort((a, b) => b.receivedAt.localeCompare(a.receivedAt) || b.sequence - a.sequence || a.kind.localeCompare(b.kind));
    case "ratingDescending": return by.sort((a, b) => b.rating - a.rating || b.receivedAt.localeCompare(a.receivedAt));
    case "filename": return by.sort((a, b) => a.filename.localeCompare(b.filename, undefined, { sensitivity: "base" }));
    case "sessionThenTime": return by.sort((a, b) => a.sessionId.localeCompare(b.sessionId) || a.sequence - b.sequence);
  }
}

// MARK: Naming (export preview)

function expandName(pattern: string, c: CaptureItem, session: ShootSession | undefined, seq: number, ext: string): string {
  const stem = c.filename.replace(/\.[^.]+$/, "");
  const safe = (s: string) => s.replace(/[/\\:]/g, "-").replace(/\s+/g, "_");
  const out = pattern.replace(/\{(\w+)(?::(\d+))?\}/g, (_, token: string, width?: string) => {
    switch (token) {
      case "orig": return stem;
      case "session": return safe(session?.name ?? "Session");
      case "date": return c.capturedAt.slice(0, 10);
      case "seq": return String(seq).padStart(Number(width ?? 4), "0");
      case "camera": return safe(session?.camera ? cameraDisplayName(session.camera) : "Camera");
      case "client": return safe(session?.workflowTag ?? "client");
      case "rating": return String(c.rating);
      case "label": return c.colorLabel === "none" ? "" : c.colorLabel;
      case "pick": return c.flag === "pick" ? "pick" : "";
      default: return "";
    }
  });
  return `${out || stem}.${ext}`;
}

function layoutDir(layout: ExportOptions["layout"], c: CaptureItem, session: ShootSession | undefined): string {
  switch (layout) {
    case "flat": return "";
    case "dated": return `${c.capturedAt.slice(0, 4)}/${c.capturedAt.slice(0, 10)}`;
    case "bySession": return (session?.name ?? "Session").replace(/[/\\:]/g, "-");
    case "captureOne": return `${(session?.name ?? "Session").replace(/[/\\:]/g, "-")}/Output`;
    case "byRating": return c.rating > 0 ? `${c.rating} star${c.rating === 1 ? "" : "s"}` : "Unrated";
    case "captureOneSessionRoot": return c.flag === "pick" ? "Selects" : c.flag === "reject" ? "Trash" : "Capture";
  }
}

// MARK: Mock backend

interface Edit {
  title: string;
  count: number;
  undo: () => void;
  redo: () => void;
}

interface MockShoot {
  state: ShootState;
  kind: "camera" | "demo" | "ftp";
  scene: Scene;
  seedBase: number;
  frame: number;
  timers: number[];
  liveTimer: number | null;
  liveSpec: SceneSpec;
  liveSeq: number;
}

const SETTINGS_KEY = "openTether.mock.settings";

export function createMockBackend(): Backend {
  const now = Date.now();
  const built = buildLibrary(now);
  const { collections, members } = buildCollections(built.captures, now);
  const state = {
    settings: loadSettings(),
    permissions: { localNetwork: "notDetermined", photos: "notDetermined" } as Record<PermissionKind, PermissionState>,
    sessions: built.sessions,
    captures: new Map(built.captures.map((c) => [c.id, c] as const)),
    order: built.captures.map((c) => c.id),
    meta: built.meta,
    tags: built.tags,
    history: built.history,
    collections,
    members,
    looks: LOOK_RECIPES.map((l) => lookDescriptor(l.id, l.name, "Open Tether", l.recipe)),
    recipes: new Map<string, LookRecipe>(LOOK_RECIPES.map((l) => [l.id, l.recipe])),
    templates: buildTemplates(now),
    ftpDests: buildFtpDestinations(),
    ftpPasswords: new Map<string, string>([["ftp-nas", "studio-pass"]]),
    folderDests: buildFolderDestinations(),
    jobs: [] as ExportJob[],
    exportsPaused: false,
    undo: [] as Edit[],
    redo: [] as Edit[],
    viewStates: new Map<string, ViewState>(),
    lastSource: null as string | null,
    recents: { tags: ["hero", "lookbook", "headshots", "smile"], collectionIds: ["col-selects"] } as Recents,
    exportMemory: {
      destination: { kind: "photos" },
      scope: "picks",
      options: {
        applyLook: true, maxLongEdge: null, jpegQuality: 0.92, includeRaw: false, namingPattern: "{orig}", layout: "flat",
        embedMetadata: true, writeSidecars: true, writeManifest: false, rawOutput: "original",
      },
    } as ExportMemory,
    metadata: {
      creator: "Brady Jordan", copyright: "© {year} Brady Jordan", captionTemplate: "{session} – {date}", hierarchicalRoot: "Tether",
      sessionAsKeyword: true, embedInJpeg: true, writeSidecarsForRaw: true, writeSidecarsForJpeg: false, readIncomingXmp: true,
    } as MetadataProfile,
    shoot: null as MockShoot | null,
    discovery: { running: false, cameras: [] as DiscoveredCamera[], timers: [] as number[] },
    usbDevices: [] as UsbCandidate[],
    ftp: {
      running: false, username: "", password: "", port: 2121, boundPort: null, addresses: [], clients: 0, lastError: null, received: [],
    } as FtpReceiverStatus,
    known: [
      { camera: CAMERAS.r5, host: null, lastSeen: iso(now - 3 * DAY) },
      { camera: CAMERAS.a7iv, host: null, lastSeen: iso(now - DAY) },
      { camera: CAMERAS.xt5, host: "192.168.0.1", lastSeen: iso(now - 9 * DAY) },
    ] as KnownCamera[],
    log: [] as PtpLogLine[],
    connectAbort: false,
  };
  state.ftp.username = state.settings.ftpUsername;
  state.ftp.password = state.settings.ftpPassword;
  state.ftp.port = state.settings.ftpPort;
  seedJobs();

  // MARK: Events

  const handlers = new Map<string, Set<(p: unknown) => void>>();
  function on<E extends EventName>(event: E, handler: (payload: EventMap[E]) => void): Unlisten {
    const set = handlers.get(event) ?? new Set();
    set.add(handler as (p: unknown) => void);
    handlers.set(event, set);
    return () => set.delete(handler as (p: unknown) => void);
  }
  function emit<E extends EventName>(event: E, payload: EventMap[E]) {
    const set = handlers.get(event);
    if (!set) return;
    const copy = clone(payload);
    queueMicrotask(() => set.forEach((h) => h(copy)));
  }
  function toast(text: string, symbol: string, action?: ToastMessage["action"]) {
    emit("toast", { id: uid("toast"), text, symbol, action: action ?? null });
  }
  let libraryTimer: number | null = null;
  function libraryChanged(reason: string) {
    if (libraryTimer != null) return;
    libraryTimer = window.setTimeout(() => {
      libraryTimer = null;
      emit("library:changed", { reason });
    }, 120);
  }
  function log(direction: PtpLogLine["direction"], text: string) {
    state.log.push({ at: iso(Date.now()), direction, text });
    if (state.log.length > 400) state.log.splice(0, state.log.length - 400);
  }

  // MARK: Helpers

  function loadSettings(): AppSettings {
    const fallback: AppSettings = { hasOnboarded: false, ftpUsername: "tether", ftpPassword: "k7m2xq9p", ftpPort: 2121 };
    try {
      if (new URLSearchParams(location.search).has("reset")) localStorage.removeItem(SETTINGS_KEY);
      const raw = localStorage.getItem(SETTINGS_KEY);
      return raw ? { ...fallback, ...(JSON.parse(raw) as Partial<AppSettings>) } : fallback;
    } catch {
      return fallback;
    }
  }
  function saveSettings() {
    try {
      localStorage.setItem(SETTINGS_KEY, JSON.stringify(state.settings));
    } catch {
      /* private mode */
    }
  }
  const session = (id: string) => state.sessions.find((s) => s.id === id);
  const capture = (id: string) => state.captures.get(id);
  const allCaptures = () => state.order.map((id) => state.captures.get(id)).filter((c): c is CaptureItem => !!c);
  const tagsOf = (id: string) => state.tags.get(id) ?? new Set<string>();
  const ctx = (): MatchContext => ({
    tags: tagsOf, sessionName: (id) => session(id)?.name ?? "", exported: (id) => state.history.get(id) ?? [], now: Date.now(),
  });
  const collection = (id: string) => state.collections.find((c) => c.id === id);

  function counts(sessionId: string): SessionCounts {
    const c: SessionCounts = { total: 0, ready: 0, picks: 0, rejects: 0, rated: 0, failed: 0 };
    for (const item of allCaptures()) {
      if (item.sessionId !== sessionId) continue;
      c.total++;
      if (item.state.kind === "ready") c.ready++;
      if (item.state.kind === "failed") c.failed++;
      if (item.flag === "pick") c.picks++;
      if (item.flag === "reject") c.rejects++;
      if (item.rating > 0) c.rated++;
    }
    return c;
  }
  function summary(s: ShootSession): SessionSummary {
    const recent = allCaptures().filter((c) => c.sessionId === s.id && c.state.kind === "ready" && c.kind !== "raw")
      .sort((a, b) => b.receivedAt.localeCompare(a.receivedAt)).slice(0, 3);
    return { session: s, counts: counts(s.id), recent };
  }

  function sourceItems(source: LibrarySource): CaptureItem[] {
    const all = allCaptures();
    switch (source.kind) {
      case "session": return all.filter((c) => c.sessionId === source.id);
      case "camera": return all.filter((c) => c.cameraId === source.id);
      case "collection": {
        const col = collection(source.id);
        if (!col) return [];
        if (col.kind === "manual") {
          const m = state.members.get(col.id) ?? new Set();
          return all.filter((c) => m.has(c.id));
        }
        const rule = col.rule ?? {};
        return all.filter((c) => matches(rule, c, ctx()));
      }
    }
  }
  function query(source: LibrarySource, filter: CaptureFilter): CaptureItem[] {
    const c = ctx();
    return sourceItems(source).filter((item) => matches({ readyOnly: false, ...filter }, item, c) && item.state.kind !== "announced");
  }

  /** Expands a selection to include each item's RAW/JPEG twin. */
  function withPairs(ids: string[]): CaptureItem[] {
    const seen = new Set(ids);
    const out = ids.map(capture).filter((c): c is CaptureItem => !!c);
    for (const item of [...out]) {
      for (const twin of allCaptures()) {
        if (twin.sessionId === item.sessionId && twin.pairKey === item.pairKey && !seen.has(twin.id)) {
          out.push(twin);
          seen.add(twin.id);
        }
      }
    }
    return out;
  }

  function undoState(): UndoState {
    return { undoTitle: state.undo.at(-1)?.title ?? null, redoTitle: state.redo.at(-1)?.title ?? null };
  }
  function push(edit: Edit) {
    state.undo.push(edit);
    if (state.undo.length > 100) state.undo.shift();
    state.redo = [];
    emit("undo:state", undoState());
  }
  function changed(ids: string[]) {
    const items = ids.map(capture).filter((c): c is CaptureItem => !!c);
    emit("captures:changed", items);
    const shoot = state.shoot;
    if (shoot) {
      for (const item of items) {
        const i = shoot.state.items.findIndex((x) => x.id === item.id);
        if (i >= 0) {
          shoot.state.items[i] = item;
          emit("capture:updated", item);
        }
      }
    }
    libraryChanged("review");
  }
  function setField<K extends "rating" | "flag" | "colorLabel">(items: CaptureItem[], key: K, value: CaptureItem[K] | Map<string, CaptureItem[K]>) {
    for (const item of items) {
      const v = value instanceof Map ? value.get(item.id) : value;
      if (v === undefined) continue;
      const next = { ...item, [key]: v };
      state.captures.set(item.id, next);
    }
  }

  function lookRecipe(look: LookStack | null | undefined) {
    if (!look?.lookId || look.strength <= 0) return null;
    const recipe = state.recipes.get(look.lookId);
    return recipe ? { recipe, strength: look.strength } : null;
  }

  function imageUrl(c: Pick<CaptureItem, "id" | "revision">, variant: ImageVariant, opts?: ImageOptions): string {
    const spec = state.meta.get(c.id);
    if (!spec) return "";
    const look = variant === "original" ? null : lookRecipe(opts?.look);
    const edge = variant === "thumb" ? 360 : variant === "preview" ? 1600 : 2400;
    const key = `${c.id}|${variant}|${look ? `${opts?.look?.lookId}@${look.strength.toFixed(2)}` : "-"}`;
    return renderFrame(key, spec, edge, look);
  }

  // MARK: Shoot simulation

  function reconnectStrategy(s: ShootSession, identity: CameraIdentity | null): ReconnectStrategy {
    switch (s.transport) {
      case "usb": return { kind: "waitForUsbDevice", serial: identity?.serialNumber ?? null };
      case "ptpip": return s.lastHost ? { kind: "retryHost", host: s.lastHost, port: 15740, vendor: identity?.vendor ?? null } : { kind: "startFresh" };
      case "ricohHTTP": return { kind: "retryRicoh", host: s.lastHost ?? "192.168.0.1" };
      case "http": return s.lastHost && identity ? { kind: "retryHttp", host: s.lastHost, vendor: identity.vendor } : { kind: "startFresh" };
      case "ftpPush": return { kind: "nothingToDo" };
      default: return { kind: "startFresh" };
    }
  }

  function startShoot(s: ShootSession, identity: CameraIdentity | null, kind: MockShoot["kind"], opts: { disconnected?: string } = {}): ShootState {
    stopShoot(false);
    s.status = "active";
    s.endedAt = null;
    if (identity) {
      s.camera = identity;
      s.transport = identity.transport;
    }
    if (kind === "ftp") s.transport = "ftpPush";
    const items = allCaptures().filter((c) => c.sessionId === s.id);
    const scenes: Scene[] = ["landscape", "portrait", "product", "city", "sea"];
    const scene: Scene = kind === "demo" ? "landscape" : items.length ? (state.meta.get(items[0].id)?.scene ?? "portrait") : scenes[Math.floor(Math.random() * scenes.length)];
    const memoryOffer = identity && identity.id === CAMERAS.r5.id && !s.lookId
      ? { look: { lookId: "ot.portrait", strength: 1 }, lookName: "Warm Portrait", destination: "both" as CaptureDestination }
      : null;
    const st: ShootState = {
      session: s,
      identity,
      status: opts.disconnected ? { kind: "disconnected", reason: opts.disconnected } : { kind: "ready" },
      items,
      properties: identity && hasCap(identity.capabilities, Cap.propertyControl) ? initialProperties(true) : identity ? initialProperties(false).slice(0, 5) : [],
      selectedItemId: items.filter((i) => i.state.kind === "ready").at(-1)?.id ?? null,
      downloadsInFlight: 0,
      liveViewActive: false,
      look: { lookId: s.lookId, strength: s.lookStrength },
      reconnect: reconnectStrategy(s, identity),
      restoreOffer: memoryOffer,
      isDemo: kind === "demo",
    };
    const shoot: MockShoot = {
      state: st, kind, scene, seedBase: Math.floor(Math.random() * 100000), frame: items.length, timers: [], liveTimer: null,
      liveSpec: { scene, seed: 4242, t: 0.35, tall: false, ev: 0 }, liveSeq: 0,
    };
    state.shoot = shoot;
    if (kind === "demo") scheduleDemo(shoot, 1200);
    if (kind === "ftp") scheduleFtp(shoot, 4000);
    log("note", `Session ${s.name} opened (${kind}${identity ? `, ${cameraDisplayName(identity)}` : ""})`);
    emit("shoot:started", st);
    emit("sessions:changed", { reason: "shoot started" });
    return clone(st);
  }

  function stopShoot(ended: boolean) {
    const shoot = state.shoot;
    if (!shoot) return;
    shoot.timers.forEach((t) => clearTimeout(t));
    if (shoot.liveTimer != null) clearInterval(shoot.liveTimer);
    state.shoot = null;
    if (ended) {
      const s = shoot.state.session;
      s.status = "ended";
      s.endedAt = iso(Date.now());
      emit("shoot:ended", { sessionId: s.id });
      emit("sessions:changed", { reason: "shoot ended" });
      libraryChanged("shoot ended");
    }
  }

  function scheduleDemo(shoot: MockShoot, delay: number) {
    const t = window.setTimeout(() => {
      if (state.shoot !== shoot) return;
      if (shoot.frame < 40) {
        ingestFrame(shoot, "demo");
        scheduleDemo(shoot, 3500);
      }
    }, delay);
    shoot.timers.push(t);
  }

  function scheduleFtp(shoot: MockShoot, delay: number) {
    const t = window.setTimeout(() => {
      if (state.shoot !== shoot || !state.ftp.running) {
        if (state.shoot === shoot) scheduleFtp(shoot, 3000);
        return;
      }
      ingestFrame(shoot, "ftp");
      scheduleFtp(shoot, 5000);
    }, delay);
    shoot.timers.push(t);
  }

  function ingestFrame(shoot: MockShoot, origin: "camera" | "demo" | "ftp") {
    const st = shoot.state;
    shoot.frame += 1;
    const seq = 1000 + shoot.frame;
    const identity = st.identity;
    const r = rng(shoot.seedBase + shoot.frame * 31);
    const ev = st.properties.length ? evFromProperties(st.properties) : (r() - 0.5) * 0.6;
    const spec: SceneSpec = {
      scene: shoot.kind === "demo" ? (["landscape", "sea", "city"] as Scene[])[Math.floor(shoot.frame / 4) % 3] : shoot.scene,
      seed: shoot.seedBase + shoot.frame * 13,
      t: (shoot.frame % 9) / 8,
      tall: shoot.scene === "portrait" && r() > 0.5,
      ev,
    };
    const pairs = !!identity && (identity.vendor === "canon" || identity.vendor === "nikon") && st.session.destination !== "card";
    const kinds: MediaKind[] = pairs ? ["raw", "jpeg"] : ["jpeg"];
    const vendor: CameraVendor | null = identity?.vendor ?? (origin === "ftp" ? "fujifilm" : null);
    const at = Date.now();
    const exposure = st.properties.length ? exposureSummary(st.properties) : exposureFor(r, spec.scene);
    kinds.forEach((kind, k) => {
      const filename = filenameFor(vendor, seq, kind);
      const id = uid("cap");
      const long = kind === "raw" ? 8192 : 6000;
      const bytes = kind === "raw" ? 45_000_000 + Math.floor(r() * 9_000_000) : 10_000_000 + Math.floor(r() * 5_000_000);
      const item: CaptureItem = {
        id, sessionId: st.session.id, sequence: seq, filename, kind, bytes,
        width: spec.tall ? Math.round((long * 2) / 3) : long, height: spec.tall ? long : Math.round((long * 2) / 3),
        capturedAt: iso(at), receivedAt: iso(at), rating: 0, flag: "none", colorLabel: "none",
        state: { kind: "downloading", received: 0, total: bytes }, pairKey: filename.replace(/\.[^.]+$/, "").toUpperCase(),
        source: identity?.transport ?? (origin === "ftp" ? "ftpPush" : "ftpPush"), lookId: st.look.lookId, exposure,
        cameraId: identity?.id ?? null, revision: 1,
      };
      state.meta.set(id, spec);
      state.captures.set(id, item);
      state.order.push(id);
      const tpl = state.templates.find((t) => st.session.name.toLowerCase().includes(t.name.toLowerCase()));
      state.tags.set(id, new Set(tpl?.tags ?? []));
      st.items.push(item);
      st.downloadsInFlight += 1;
      st.session.captureCount += 1;
      log("event", `ObjectAdded handle 0x${(0x9000 + seq * 2 + k).toString(16)} ${filename}`);
      emit("capture:added", item);
      emit("shoot:downloads", { inFlight: st.downloadsInFlight });
      if (origin === "ftp") {
        const file = { id: uid("ftp"), name: filename, bytes, from: "192.168.1.31", at: iso(at), durationSeconds: 0.6 + r() };
        state.ftp.received.unshift(file);
        state.ftp.received = state.ftp.received.slice(0, 200);
        emit("ftp:file", file);
      }
      const steps = [0.35, 0.7, 1];
      steps.forEach((p, i) => {
        const timer = window.setTimeout(() => {
          if (state.shoot !== shoot) return;
          const cur = state.captures.get(id);
          if (!cur) return;
          const done = p >= 1;
          const next: CaptureItem = { ...cur, state: done ? { kind: "ready" } : { kind: "downloading", received: Math.round(bytes * p), total: bytes }, receivedAt: done ? iso(Date.now()) : cur.receivedAt };
          state.captures.set(id, next);
          const idx = st.items.findIndex((x) => x.id === id);
          if (idx >= 0) st.items[idx] = next;
          emit("capture:updated", next);
          if (done) {
            st.downloadsInFlight = Math.max(0, st.downloadsInFlight - 1);
            emit("shoot:downloads", { inFlight: st.downloadsInFlight });
            log("out", `GetObject ${filename} (${(bytes / 1e6).toFixed(1)} MB)`);
            if (st.session.showNewestCapture && kind !== "raw") {
              st.selectedItemId = id;
              emit("shoot:selection", { captureId: id });
            }
            libraryChanged("capture");
          }
        }, 260 + i * 280 + k * 160);
        shoot.timers.push(timer);
      });
    });
  }

  function requireShoot(): MockShoot {
    if (!state.shoot) throw new MockError("noShoot", "No session is open.");
    return state.shoot;
  }

  function setStatus(shoot: MockShoot, status: ShootState["status"]) {
    shoot.state.status = status;
    emit("shoot:status", { status });
  }

  function stopLive(shoot: MockShoot) {
    if (shoot.liveTimer != null) clearInterval(shoot.liveTimer);
    shoot.liveTimer = null;
    shoot.state.liveViewActive = false;
    emit("shoot:liveview", { active: false });
  }

  function simulateDisconnect(reason = "The camera stopped answering. Was the cable unplugged?") {
    const shoot = state.shoot;
    if (!shoot || shoot.kind !== "camera") return;
    stopLive(shoot);
    setStatus(shoot, { kind: "disconnected", reason });
    log("note", `Transport closed: ${reason}`);
  }

  // MARK: Connect simulation

  const stepTitles = (transport: TransportKind): Record<ConnectStep, string> => ({
    link: transport === "usb" ? "Open the USB connection" : transport === "ftpPush" ? "Start the FTP server" : "Reach the camera",
    session: transport === "ricohHTTP" || transport === "http" ? "Say hello over HTTP" : "Open a PTP session",
    identify: "Read the camera's identity",
    prepare: "Switch to remote mode",
    ready: "Ready to shoot",
  });

  async function runConnect(transport: TransportKind, failAt: ConnectStep | null, failure: string): Promise<void> {
    state.connectAbort = false;
    const titles = stepTitles(transport);
    const order: ConnectStep[] = ["link", "session", "identify", "prepare", "ready"];
    const progress: ConnectProgress = {
      attemptId: uid("connect"), transport, failure: null,
      steps: order.map((step) => ({ step, title: titles[step], state: "pending" })),
    };
    for (let i = 0; i < order.length; i++) {
      progress.steps[i].state = "running";
      emit("connect:progress", progress);
      await wait(380 + Math.random() * 200);
      if (state.connectAbort) {
        progress.steps[i].state = "failed";
        progress.failure = "Cancelled.";
        emit("connect:progress", progress);
        throw new MockError("cancelled", "Cancelled.");
      }
      if (failAt === order[i]) {
        progress.steps[i].state = "failed";
        progress.failure = failure;
        emit("connect:progress", progress);
        log("note", failure);
        throw new MockError("connectFailed", failure);
      }
      progress.steps[i].state = "done";
      log("out", `${titles[order[i]]}: ok`);
    }
    emit("connect:progress", progress);
  }

  function sessionFor(id: string | null): ShootSession {
    if (id) {
      const s = session(id);
      if (s) return s;
    }
    const s: ShootSession = {
      id: uid("session"), name: `Shoot ${new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short", year: "numeric" }).format(new Date())}`,
      createdAt: iso(Date.now()), endedAt: null, status: "active", camera: null, transport: null, lastHost: null, destination: "both",
      routing: defaultRouting(), lookId: null, lookStrength: 1, showNewestCapture: true, workflowTag: null, captureCount: 0,
    };
    state.sessions.unshift(s);
    return s;
  }

  function rememberCamera(identity: CameraIdentity, host: string | null) {
    state.known = [{ camera: identity, host, lastSeen: iso(Date.now()) }, ...state.known.filter((k) => k.camera.id !== identity.id)];
  }

  // MARK: Diagnostics

  async function runDiagnostics(wired: boolean, host: string | null, port: number | null): Promise<DiagnosticReport> {
    const checks: DiagnosticCheck[] = wired
      ? [
          { id: "bus", title: "Camera on the cable", tip: "Use a data-capable USB-C cable straight into the Mac, not through a hub, and switch the camera on.", outcome: { kind: "pending" } },
          { id: "auth", title: "Permissions", tip: "System Settings › Privacy & Security › Camera access for Open Tether.", outcome: { kind: "pending" } },
          { id: "session", title: "Open a session", tip: "Quit Image Capture, Photos, EOS Utility or anything else that holds the camera.", outcome: { kind: "pending" } },
          { id: "ptp", title: "Talk PTP", tip: "Set the camera's USB mode to PC / PTP / Tether (see the setup guides).", outcome: { kind: "pending" } },
          { id: "power", title: "Power", tip: "A Mac powers itself; a low camera battery can drop the link.", outcome: { kind: "pending" } },
        ]
      : [
          { id: "wifi", title: "On the camera's Wi-Fi", tip: "Join the camera's network from the Wi-Fi menu in the menu bar.", outcome: { kind: "pending" } },
          { id: "ip", title: "Address on that network", tip: "The Mac needs an address from the camera (usually 192.168.x.x).", outcome: { kind: "pending" } },
          { id: "tcp", title: "Camera answers", tip: "PTP/IP listens on TCP 15740; Ricoh on HTTP port 80. The camera must be in its remote/PC-connection mode.", outcome: { kind: "pending" } },
        ];
    const report: DiagnosticReport = { id: uid("diag"), wired, verdict: "Checking…", checks, finishedAt: null, shareText: "" };
    const usb = state.usbDevices[0] ?? null;
    const reachable = !!host && /^192\.168\./.test(host);
    for (const c of checks) {
      c.outcome = { kind: "running" };
      emit("diagnostics:update", report);
      await wait(550);
      switch (c.id) {
        case "bus": c.outcome = usb || state.shoot?.state.identity ? { kind: "pass", detail: `${usb?.name ?? "Canon EOS R5"} is on the bus.` } : { kind: "fail", detail: "No camera on the USB bus." }; break;
        case "auth": c.outcome = { kind: "pass", detail: "Open Tether may talk to cameras." }; break;
        case "session": c.outcome = usb ? { kind: "pass", detail: "Session opened and closed cleanly." } : { kind: "skipped", detail: "No camera to open." }; break;
        case "ptp": c.outcome = usb ? { kind: "pass", detail: "DeviceInfo: Canon Inc. EOS R5, firmware 1.8.1." } : { kind: "skipped", detail: "No session." }; break;
        case "power": c.outcome = { kind: "skipped", detail: "Not needed on a Mac." }; break;
        case "wifi": c.outcome = { kind: "warn", detail: "macOS does not share the network name with apps; check the Wi-Fi menu shows the camera's network." }; break;
        case "ip": c.outcome = { kind: "pass", detail: "192.168.1.24 on en0." }; break;
        case "tcp": c.outcome = reachable ? { kind: "pass", detail: `${host}:${port ?? 15740} accepted a connection in 18 ms.` } : { kind: "fail", detail: `Nothing answered at ${host ?? "?"}:${port ?? 15740}.` }; break;
      }
      emit("diagnostics:update", report);
    }
    const failed = checks.filter((c) => c.outcome.kind === "fail");
    report.verdict = failed.length === 0 ? "Everything checks out" : `Stuck at: ${failed[0].title}`;
    report.finishedAt = iso(Date.now());
    report.shareText = [`Open Tether ${wired ? "cable" : "wireless"} diagnostic`, ...checks.map((c) => `- ${c.title}: ${c.outcome.kind}${"detail" in c.outcome ? ` (${c.outcome.detail})` : ""}`)].join("\n");
    emit("diagnostics:update", report);
    return report;
  }

  // MARK: Export queue

  function scopeFilter(scope: ExportScope, items: CaptureItem[]): CaptureItem[] {
    const ready = items.filter((c) => c.state.kind === "ready");
    switch (scope.kind) {
      case "all": return ready.filter((c) => c.flag !== "reject");
      case "collection": {
        const col = collection(scope.collectionId);
        const inCol = col ? new Set(sourceItems({ kind: "collection", id: col.id }).map((c) => c.id)) : new Set<string>();
        return ready.filter((c) => c.flag !== "reject" && (inCol.size === 0 || inCol.has(c.id)));
      }
      case "picks": return ready.filter((c) => c.flag === "pick");
      case "rated": return ready.filter((c) => c.rating >= scope.min && c.flag !== "reject");
      case "selected": {
        const item = ready.find((c) => c.id === scope.captureId);
        return item ? ready.filter((c) => c.pairKey === item.pairKey && c.sessionId === item.sessionId) : [];
      }
      case "selection": {
        const ids = new Set(scope.ids);
        return ready.filter((c) => ids.has(c.id));
      }
    }
  }

  function planItems(req: ExportRequest) {
    const base = req.captureIds
      ? req.captureIds.map(capture).filter((c): c is CaptureItem => !!c)
      : allCaptures().filter((c) => c.sessionId === req.sessionId);
    let chosen = scopeFilter(req.scope, base);
    // Pairs ride along with a pick of either half.
    if (req.options.includeRaw && req.scope.kind !== "selection") chosen = withPairs(chosen.map((c) => c.id)).filter((c) => c.state.kind === "ready");
    chosen = chosen.filter((c) => (c.kind !== "raw" || req.options.includeRaw) && c.kind !== "video" && c.kind !== "other");
    return chosen;
  }

  function deliveredPath(c: CaptureItem, opts: ExportOptions, seq: number): string {
    const s = session(c.sessionId);
    const ext = c.kind === "raw" ? (opts.rawOutput === "original" ? c.filename.split(".").pop() ?? "raw" : { jpeg: "jpg", heif: "heic", tiff16: "tif", original: "" }[opts.rawOutput]) : "jpg";
    const name = expandName(opts.namingPattern, c, s, seq, ext.toLowerCase());
    const dir = layoutDir(opts.layout, c, s);
    return dir ? `${dir}/${name}` : name;
  }

  function destinationName(req: ExportRequest["destination"]): string {
    switch (req.kind) {
      case "photos": return "Photos";
      case "files": return "Files";
      case "ftp": return `FTP · ${state.ftpDests.find((d) => d.id === req.destinationId)?.name ?? "server"}`;
      case "folder": return state.folderDests.find((d) => d.id === req.destinationId)?.name ?? "Folder";
    }
  }

  function makeJobs(req: ExportRequest): ExportJob[] {
    const chosen = planItems(req);
    const groups = new Map<string, CaptureItem[]>();
    for (const c of chosen) groups.set(c.sessionId, [...(groups.get(c.sessionId) ?? []), c]);
    const jobs: ExportJob[] = [];
    for (const [sid, group] of [...groups.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
      const s = session(sid);
      const look = req.look ?? { lookId: s?.lookId ?? null, strength: s?.lookStrength ?? 1 };
      const items = group.map((c, i) => ({
        id: c.id, filename: c.filename, kind: c.kind, bytes: c.bytes, state: { kind: "pending" as const },
        deliveredPath: deliveredPath(c, req.options, i + 1), isCompanion: false,
      }));
      if (req.options.writeSidecars) {
        for (const c of group.filter((x) => x.kind === "raw")) {
          items.push({ id: `${c.id}.xmp`, filename: c.filename.replace(/\.[^.]+$/, ".xmp"), kind: "other", bytes: 4096, state: { kind: "pending" }, deliveredPath: deliveredPath(c, req.options, 0).replace(/\.[^.]+$/, ".xmp"), isCompanion: true });
        }
      }
      jobs.push({
        id: uid("job"), sessionId: sid, destination: req.destination, destinationName: destinationName(req.destination), options: req.options,
        look, createdAt: iso(Date.now()), status: { kind: "queued" }, items, progress: 0, attempts: 0,
      });
    }
    return jobs;
  }

  function seedJobs() {
    const s = state.sessions.find((x) => x.id === "session-3");
    if (!s) return;
    const picks = [...state.captures.values()].filter((c) => c.sessionId === s.id && c.flag === "pick").slice(0, 6);
    const created = new Date(s.createdAt).getTime() + 4 * 3600_000;
    state.jobs.push({
      id: "job-seed-1", sessionId: s.id, destination: { kind: "ftp", destinationId: "ftp-nas" }, destinationName: "FTP · Studio NAS",
      options: { ...state.exportMemory.options }, look: { lookId: s.lookId, strength: 1 }, createdAt: iso(created), status: { kind: "completed" },
      items: picks.map((c) => ({ id: c.id, filename: c.filename, kind: c.kind, bytes: c.bytes, state: { kind: "done", path: `/Incoming/Tether/${c.filename}` }, deliveredPath: c.filename, isCompanion: false })),
      progress: 1, attempts: 1,
    });
  }

  let exportTimer: number | null = null;
  function kickExports() {
    if (exportTimer != null) return;
    exportTimer = window.setInterval(tickExports, 220);
  }
  function tickExports() {
    if (state.exportsPaused) return;
    const job = state.jobs.find((j) => j.status.kind === "running") ?? state.jobs.find((j) => j.status.kind === "queued");
    if (!job) {
      if (exportTimer != null) clearInterval(exportTimer);
      exportTimer = null;
      return;
    }
    if (job.status.kind === "queued") {
      job.status = { kind: "running" };
      job.attempts += 1;
    }
    const item = job.items.find((i) => i.state.kind === "pending" || i.state.kind === "uploading");
    if (item) {
      const p = item.state.kind === "uploading" ? item.state.progress : 0;
      const next = Math.min(1, p + (item.isCompanion ? 1 : 0.34 + Math.random() * 0.2));
      const failHere = job.destination.kind === "ftp" && job.destination.destinationId === "ftp-acme" && job.attempts === 1 && job.items.indexOf(item) === 2;
      if (failHere && next >= 0.6) {
        item.state = { kind: "failed", reason: "550 Permission denied on /selects" };
      } else if (next >= 1) {
        item.state = { kind: "done", path: item.deliveredPath };
        if (!item.isCompanion) {
          const key = job.destination.kind === "folder" ? "files" : job.destination.kind;
          state.history.set(item.id, [...(state.history.get(item.id) ?? []), { destination: key, at: iso(Date.now()), remoteId: item.deliveredPath }]);
        }
      } else {
        item.state = { kind: "uploading", progress: next };
      }
    }
    const done = job.items.filter((i) => i.state.kind === "done" || i.state.kind === "skipped").length;
    const partial = job.items.reduce((acc, i) => acc + (i.state.kind === "uploading" ? i.state.progress : 0), 0);
    job.progress = job.items.length ? (done + partial) / job.items.length : 1;
    const pending = job.items.some((i) => i.state.kind === "pending" || i.state.kind === "uploading");
    if (!pending) {
      const failed = job.items.filter((i) => i.state.kind === "failed").length;
      job.status = failed ? { kind: "failed", message: `${failed} frame${failed === 1 ? "" : "s"} failed` } : { kind: "completed" };
      emit("export:job", job);
      emit("export:finished", job);
      toast(failed ? "Export finished with errors" : `Export to ${job.destinationName} finished`, failed ? "exclamationmark.triangle" : "checkmark.circle");
      libraryChanged("export");
      return;
    }
    emit("export:job", job);
  }

  // MARK: Backend object

  const ok = async <T,>(v: T, ms = 30): Promise<T> => {
    await wait(ms);
    return clone(v);
  };

  const backend: Backend = {
    kind: "mock",
    on,
    imageUrl,

    // App
    appInfo: () => ok({ version: "0.1.0", build: "1", platform: "macOS (browser mock)", backend: "mock" as const }),
    settingsGet: () => ok(state.settings),
    async settingsUpdate({ patch }) {
      state.settings = { ...state.settings, ...patch };
      saveSettings();
      Object.assign(state.ftp, { username: state.settings.ftpUsername, password: state.settings.ftpPassword, port: state.settings.ftpPort });
      if (state.ftp.running && ("ftpPort" in patch || "ftpUsername" in patch || "ftpPassword" in patch)) {
        state.ftp.boundPort = state.settings.ftpPort;
        emit("ftp:status", state.ftp);
      }
      return ok(state.settings);
    },
    permissionsStatus: () => ok(state.permissions),
    async permissionsRequest({ kind }) {
      await wait(600);
      state.permissions[kind] = "granted";
      return clone(state.permissions[kind]);
    },
    metadataProfileGet: () => ok(state.metadata),
    async metadataProfileSet({ profile }) {
      state.metadata = clone(profile);
      await wait(10);
    },
    async xmpPreview({ captureId }) {
      const c = (captureId ? capture(captureId) : null) ?? sortCaptures(allCaptures(), "captureTimeDescending")[0];
      if (!c) return { filename: null, packet: null };
      const m = state.metadata;
      const s = session(c.sessionId);
      const year = new Date().getFullYear();
      const keywords = [...tagsOf(c.id), ...(m.sessionAsKeyword && s ? [s.name] : [])];
      const packet = [
        `<x:xmpmeta xmlns:x="adobe:ns:meta/">`,
        ` <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">`,
        `  <rdf:Description rdf:about=""`,
        `    xmlns:xmp="http://ns.adobe.com/xap/1.0/"`,
        `    xmlns:dc="http://purl.org/dc/elements/1.1/"`,
        `    xmlns:lr="http://ns.adobe.com/lightroom/1.0/"`,
        `    xmp:Rating="${c.flag === "reject" ? -1 : c.rating}"`,
        c.colorLabel !== "none" ? `    xmp:Label="${c.colorLabel[0].toUpperCase()}${c.colorLabel.slice(1)}"` : null,
        `    xmp:CreateDate="${c.capturedAt}">`,
        m.creator ? `   <dc:creator><rdf:Seq><rdf:li>${m.creator}</rdf:li></rdf:Seq></dc:creator>` : null,
        m.copyright ? `   <dc:rights><rdf:Alt><rdf:li xml:lang="x-default">${m.copyright.replace("{year}", String(year))}</rdf:li></rdf:Alt></dc:rights>` : null,
        m.captionTemplate ? `   <dc:description><rdf:Alt><rdf:li xml:lang="x-default">${m.captionTemplate.replace("{session}", s?.name ?? "").replace("{date}", c.capturedAt.slice(0, 10))}</rdf:li></rdf:Alt></dc:description>` : null,
        keywords.length ? `   <dc:subject><rdf:Bag>${keywords.map((k) => `<rdf:li>${k}</rdf:li>`).join("")}</rdf:Bag></dc:subject>` : null,
        keywords.length && m.hierarchicalRoot ? `   <lr:hierarchicalSubject><rdf:Bag>${keywords.map((k) => `<rdf:li>${m.hierarchicalRoot}|${k}</rdf:li>`).join("")}</rdf:Bag></lr:hierarchicalSubject>` : null,
        `  </rdf:Description>`,
        ` </rdf:RDF>`,
        `</x:xmpmeta>`,
      ].filter((l): l is string => l != null).join("\n");
      return ok({ filename: c.filename, packet });
    },
    viewStateGet: ({ key }) => ok(state.viewStates.get(key) ?? null),
    async viewStateSet({ key, state: v }) {
      state.viewStates.set(key, clone(v));
      state.lastSource = key;
    },
    lastSourceGet: () => ok(state.lastSource),
    recentsGet: () => ok(state.recents),
    exportMemoryGet: () => ok(state.exportMemory),
    async dialogPick({ kind, multiple }) {
      await wait(250);
      switch (kind) {
        case "files": return multiple ? ["~/Pictures/Imports/DSC09412.JPG", "~/Pictures/Imports/DSC09413.JPG", "~/Pictures/Imports/DSC09414.ARW"] : ["~/Pictures/Imports/DSC09412.JPG"];
        case "folder": return [`~/Pictures/Exports/Folder ${state.folderDests.length + 1}`];
        case "catalog": return ["~/Pictures/Lightroom/Lightroom Catalog.lrcat"];
        case "cube": return ["~/Downloads/Kodak 2383.cube"];
      }
    },
    async revealInFinder() {
      toast("Shown in Finder (mock)", "folder");
    },
    async openWifiSettings() {
      toast("Opens System Settings › Wi-Fi (mock)", "wifi");
    },
    ptpLog: () => ok(state.log.slice(-300)),

    // Sessions
    sessionsList: () => ok([...state.sessions].sort((a, b) => b.createdAt.localeCompare(a.createdAt)).map(summary)),
    async sessionGet({ id }) {
      const s = session(id);
      if (!s) throw new MockError("notFound", "Session not found.");
      return ok(summary(s));
    },
    sessionCaptures: ({ id }) => ok(allCaptures().filter((c) => c.sessionId === id)),
    async sessionCreate({ draft }) {
      const s: ShootSession = {
        id: uid("session"), name: draft.name.trim() || "Untitled shoot", createdAt: iso(Date.now()), endedAt: null, status: "active",
        camera: null, transport: null, lastHost: null, destination: draft.destination, routing: draft.routing, lookId: draft.lookId,
        lookStrength: 1, showNewestCapture: true, workflowTag: draft.workflowTag, captureCount: 0,
      };
      state.sessions.unshift(s);
      if (draft.templateId) {
        const t = state.templates.find((x) => x.id === draft.templateId);
        if (t) {
          t.useCount += 1;
          t.lastUsed = iso(Date.now());
        }
      }
      emit("sessions:changed", { reason: "created" });
      libraryChanged("session");
      return ok(s);
    },
    async sessionRename({ id, name }) {
      const s = session(id);
      if (!s) throw new MockError("notFound", "Session not found.");
      s.name = name.trim() || s.name;
      if (state.shoot?.state.session.id === id) emit("shoot:session", s);
      emit("sessions:changed", { reason: "renamed" });
      libraryChanged("session");
      return ok(s);
    },
    async sessionDelete({ id }) {
      if (state.shoot?.state.session.id === id) stopShoot(false);
      state.sessions = state.sessions.filter((s) => s.id !== id);
      for (const c of allCaptures()) if (c.sessionId === id) state.captures.delete(c.id);
      state.order = state.order.filter((x) => state.captures.has(x));
      emit("sessions:changed", { reason: "deleted" });
      libraryChanged("session");
      await wait(20);
    },
    async sessionDismissInterrupted({ id }) {
      const s = session(id);
      if (s) {
        s.status = "ended";
        s.endedAt = iso(Date.now());
      }
      emit("sessions:changed", { reason: "dismissed" });
      await wait(10);
    },
    async sessionResume({ id }) {
      const s = session(id);
      if (!s) throw new MockError("notFound", "Session not found.");
      await wait(150);
      const identity = s.camera;
      const kind = s.transport === "ftpPush" ? "ftp" : "camera";
      if (kind === "ftp" && !state.ftp.running) await backend.ftpReceiverStart();
      return startShoot(s, identity, kind, kind === "camera" ? { disconnected: "Resumed after the app was closed" } : {});
    },
    async sessionManifest({ id }) {
      const s = session(id);
      const base = (s?.name ?? "Session").replace(/[/\\:]/g, "-");
      toast(`Wrote ${base}.json and ${base}.csv`, "doc.text");
      return ok({ jsonPath: `~/Pictures/Open Tether/Manifests/${base}.json`, csvPath: `~/Pictures/Open Tether/Manifests/${base}.csv` });
    },
    sessionDefaults: () => ok({
      name: "", workflowTag: null, destination: "both" as CaptureDestination, routing: defaultRouting(), lookId: state.sessions[0]?.lookId ?? null,
      templateId: null, namePattern: "{date} {name}",
    }),
    templatesList: () => ok([...state.templates].sort((a, b) => (b.lastUsed ?? "").localeCompare(a.lastUsed ?? ""))),
    async templateSave({ template }) {
      const i = state.templates.findIndex((t) => t.id === template.id);
      if (i >= 0) state.templates[i] = clone(template);
      else state.templates.unshift(clone(template));
      toast(`Saved template ${template.name}`, template.symbol);
      return ok(template);
    },
    async templateDelete({ id }) {
      state.templates = state.templates.filter((t) => t.id !== id);
      await wait(10);
    },
    async templateFromSession({ sessionId }) {
      const s = session(sessionId);
      if (!s) throw new MockError("notFound", "Session not found.");
      const t: SessionTemplate = {
        id: uid("tpl"), name: s.name.split("·")[0].trim(), symbol: "camera.aperture", destination: s.destination, routing: clone(s.routing),
        look: { lookId: s.lookId, strength: s.lookStrength }, showNewestCapture: s.showNewestCapture, autoExportPicks: s.routing.autoExportPicks,
        tags: s.workflowTag ? [s.workflowTag] : [], namePattern: "{date} {name}", addToCollectionId: null, useCount: 0, lastUsed: null,
      };
      return ok(t);
    },
    templateSuggest: ({ cameraId }) => ok(cameraId === CAMERAS.a7iv.id ? "tpl-headshots" : null),
    async templateExpandName({ pattern, templateName, cameraName }) {
      const date = new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short", year: "numeric" }).format(new Date());
      const n = state.sessions.length + 1;
      const out = pattern.replace(/\{date\}/g, date).replace(/\{name\}/g, templateName).replace(/\{camera\}/g, cameraName ?? "Camera")
        .replace(/\{n\}/g, String(n)).replace(/\{weekday\}/g, new Intl.DateTimeFormat(undefined, { weekday: "long" }).format(new Date()));
      return ok(out.trim());
    },

    // Connect: USB
    async usbDevices() {
      if (state.usbDevices.length === 0) {
        window.setTimeout(() => {
          if (state.usbDevices.length) return;
          state.usbDevices = [
            { id: "usb-1", name: "Canon EOS R5", vendorGuess: "canon", usbVendorId: 0x04a9, usbProductId: 0x32f5, serialNumber: CAMERAS.r5.serialNumber },
          ];
          log("note", "ICDeviceBrowser: Canon EOS R5 added");
          emit("usb:devices", state.usbDevices);
        }, 1400);
      }
      return ok(state.usbDevices);
    },
    usbAuthorization: () => ok({ canSendPTP: true, isDenied: false, summary: "Open Tether may control cameras on this Mac." }),
    usbRequestAuthorization: () => ok({ canSendPTP: true, isDenied: false, summary: "Open Tether may control cameras on this Mac." }),
    async usbConnect({ candidateId, sessionId }) {
      const cand = state.usbDevices.find((d) => d.id === candidateId);
      if (!cand) throw new MockError("deviceGone", "The camera is no longer on the cable.");
      await runConnect("usb", null, "");
      const identity = { ...CAMERAS.r5, transport: "usb" as const };
      rememberCamera(identity, null);
      const s = sessionFor(sessionId);
      s.lastHost = null;
      return startShoot(s, identity, "camera");
    },

    // Connect: Wi-Fi
    async discoveryStart() {
      if (!state.discovery.running) {
        state.discovery.running = true;
        const found: DiscoveredCamera[] = [
          { id: "fuji-4CB10342", name: "X-T5", vendor: "fujifilm", host: "192.168.0.1", port: 15740, method: "fujiUDP", transport: "ptpip", lastSeen: iso(Date.now()), isControllable: true },
          { id: "ricoh-gr3", name: "GR III", vendor: "ricoh", host: "192.168.0.1", port: 80, method: "ricohHTTP", transport: "ricohHTTP", lastSeen: iso(Date.now()), isControllable: true },
          { id: "sony-a7iv", name: "ILCE-7M4", vendor: "sony", host: "192.168.122.1", port: 15740, method: "ssdp", transport: "ptpip", lastSeen: iso(Date.now()), isControllable: true },
          { id: "bonjour-leica", name: "Leica Q3", vendor: "leica", host: "192.168.1.40", port: 15740, method: "bonjour", transport: "ptpip", lastSeen: iso(Date.now()), isControllable: false },
        ];
        found.forEach((cam, i) => {
          const t = window.setTimeout(() => {
            if (!state.discovery.running) return;
            state.discovery.cameras = [...state.discovery.cameras.filter((c) => c.id !== cam.id), cam];
            log("note", `Discovery (${cam.method}): ${cam.name} at ${cam.host}:${cam.port}`);
            emit("discovery:cameras", state.discovery.cameras);
          }, 900 + i * 1100);
          state.discovery.timers.push(t);
        });
      }
      return ok({ running: true, cameras: state.discovery.cameras, errors: {} });
    },
    async discoveryStop() {
      state.discovery.running = false;
      state.discovery.timers.forEach((t) => clearTimeout(t));
      state.discovery.timers = [];
      await wait(5);
    },
    async discoveryAddManual({ host, port, vendor }) {
      const cam: DiscoveredCamera = {
        id: `manual-${host}:${port}`, name: vendor ? `${VENDOR_NAMES[vendor]} at ${host}` : host, vendor, host, port, method: "manual",
        transport: vendor === "ricoh" ? "ricohHTTP" : vendor === "gopro" || vendor === "osc" ? "http" : "ptpip", lastSeen: iso(Date.now()),
        isControllable: vendor ? WIRELESS_VENDORS.includes(vendor) : true,
      };
      state.discovery.cameras = [...state.discovery.cameras.filter((c) => c.id !== cam.id), cam];
      emit("discovery:cameras", state.discovery.cameras);
      return ok(cam);
    },
    async wifiConnect({ cameraId, sessionId }) {
      const cam = state.discovery.cameras.find((c) => c.id === cameraId);
      if (!cam) throw new MockError("notFound", "That camera is no longer on the network.");
      const reachable = /^192\.168\./.test(cam.host) && cam.isControllable;
      const failure = !cam.isControllable
        ? `${cam.name} can't be controlled over Wi-Fi. Use USB, or set up FTP push.`
        : `The camera did not answer at ${cam.host}:${cam.port}. Check the Mac is on the camera's Wi-Fi.`;
      await runConnect(cam.transport, reachable ? null : "link", failure);
      const identity: CameraIdentity = cam.vendor === "fujifilm" ? CAMERAS.xt5 : cam.vendor === "ricoh" ? CAMERAS.gr3
        : cam.vendor === "sony" ? { ...CAMERAS.a7iv, transport: "ptpip" } : { ...CAMERAS.r5, transport: cam.transport };
      rememberCamera(identity, cam.host);
      const s = sessionFor(sessionId);
      s.lastHost = cam.host;
      return startShoot(s, identity, "camera");
    },
    networkInfo: () => ok({ ssid: null, ssidAuthorization: "unavailable" as const, localAddresses: ["192.168.1.24"], cameraNetworkVendor: null }),
    knownCameras: () => ok(state.known),
    async connectCancel() {
      state.connectAbort = true;
      await wait(5);
    },

    // Connect: FTP receiver
    ftpReceiverStatus: () => ok(state.ftp),
    async ftpReceiverStart() {
      await wait(200);
      Object.assign(state.ftp, { running: true, boundPort: state.settings.ftpPort, addresses: ["192.168.1.24", "10.0.0.12"], lastError: null, clients: 0 });
      log("note", `FTP server listening on ${state.settings.ftpPort}`);
      emit("ftp:status", state.ftp);
      window.setTimeout(() => {
        if (!state.ftp.running) return;
        state.ftp.clients = 1;
        emit("ftp:status", state.ftp);
      }, 2500);
      return ok(state.ftp);
    },
    async ftpReceiverStop() {
      Object.assign(state.ftp, { running: false, boundPort: null, clients: 0 });
      emit("ftp:status", state.ftp);
      return ok(state.ftp);
    },
    async ftpReceiverStartSession({ sessionId }) {
      if (!state.ftp.running) await backend.ftpReceiverStart();
      const s = sessionFor(sessionId);
      return startShoot(s, null, "ftp");
    },

    // Connect: demo, diagnostics
    async demoStart() {
      if (state.shoot) return ok(state.shoot.state);
      const s: ShootSession = {
        id: uid("session"), name: "Demo shoot", createdAt: iso(Date.now()), endedAt: null, status: "active", camera: null, transport: "ftpPush",
        lastHost: null, destination: "both", routing: defaultRouting(), lookId: null, lookStrength: 1, showNewestCapture: true, workflowTag: "demo", captureCount: 0,
      };
      state.sessions.unshift(s);
      return startShoot(s, null, "demo");
    },
    diagnosticsRun: ({ wired, host, port }) => runDiagnostics(wired, host, port),

    // Shoot
    shootState: () => ok(state.shoot ? state.shoot.state : null),
    async shootCapture({ autofocus }) {
      const shoot = requireShoot();
      if (!shoot.state.identity || !hasCap(shoot.state.identity.capabilities, Cap.remoteCapture)) throw new MockError("unsupported", "This connection has no remote shutter.");
      if (shoot.state.status.kind !== "ready") throw new MockError("notReady", "The camera is busy.");
      setStatus(shoot, { kind: "capturing" });
      log("out", `InitiateCapture${autofocus ? "" : " (no AF)"}`);
      await wait(autofocus ? 260 : 120);
      if (state.shoot !== shoot) return;
      ingestFrame(shoot, "camera");
      setStatus(shoot, { kind: "ready" });
    },
    async shootSetProperty({ property, raw }) {
      const shoot = requireShoot();
      const d = shoot.state.properties.find((p) => p.property === property);
      if (!d || !d.isWritable) throw new MockError("readOnly", `${property} is read-only on this camera.`);
      const choice = d.form.kind === "choices" ? d.form.choices.find((c) => c.raw === raw) : null;
      if (!choice) throw new MockError("invalidValue", "The camera does not offer that value.");
      d.raw = raw;
      d.display = choice.display;
      if (property === "captureDestination") shoot.state.session.destination = raw as CaptureDestination;
      shoot.liveSpec.ev = evFromProperties(shoot.state.properties);
      log("out", `SetDevicePropValue ${property} = ${choice.display}`);
      await wait(60);
      emit("shoot:properties", shoot.state.properties);
    },
    async shootLiveViewStart() {
      const shoot = requireShoot();
      if (!shoot.state.identity || !hasCap(shoot.state.identity.capabilities, Cap.liveView)) throw new MockError("unsupported", "No live view on this camera.");
      await wait(700);
      if (state.shoot !== shoot) return;
      shoot.state.liveViewActive = true;
      shoot.liveSpec.ev = evFromProperties(shoot.state.properties);
      emit("shoot:liveview", { active: true });
      const start = performance.now();
      shoot.liveTimer = window.setInterval(() => {
        if (state.shoot !== shoot || !shoot.state.liveViewActive) return;
        shoot.liveSeq += 1;
        const phase = (performance.now() - start) / 1000;
        emit("liveview:frame", { sequence: shoot.liveSeq, width: 960, height: 640, url: renderLiveFrame(shoot.liveSpec, phase) });
      }, 90);
    },
    async shootLiveViewStop() {
      const shoot = requireShoot();
      stopLive(shoot);
      await wait(150);
    },
    async shootFocus() {
      requireShoot();
      await wait(450 + Math.random() * 300);
      return Math.random() > 0.15 ? "focused" : "failed";
    },
    async shootFocusTrackStart() {
      requireShoot();
      await wait(50);
    },
    async shootFocusTrackStop() {
      await wait(30);
    },
    async shootSelect({ captureId }) {
      const shoot = requireShoot();
      shoot.state.selectedItemId = captureId;
      emit("shoot:selection", { captureId });
    },
    async shootSetFollowNewest({ on: v }) {
      const shoot = requireShoot();
      shoot.state.session.showNewestCapture = v;
      emit("shoot:session", shoot.state.session);
    },
    async shootSetLook({ look }) {
      const shoot = requireShoot();
      shoot.state.look = clone(look);
      shoot.state.session.lookId = look.lookId;
      shoot.state.session.lookStrength = look.strength;
      emit("shoot:look", look);
    },
    async shootSetDestination({ destination }) {
      const shoot = requireShoot();
      shoot.state.session.destination = destination;
      const d = shoot.state.properties.find((p) => p.property === "captureDestination");
      if (d) {
        d.raw = destination;
        d.display = { card: "Card", host: "Mac", both: "Card + Mac" }[destination];
        emit("shoot:properties", shoot.state.properties);
      }
      emit("shoot:session", shoot.state.session);
    },
    async shootSetRouting({ routing }) {
      const shoot = requireShoot();
      shoot.state.session.routing = clone(routing);
      emit("shoot:session", shoot.state.session);
      if (routing.liveFolderId) {
        const f = state.folderDests.find((x) => x.id === routing.liveFolderId);
        toast(`Hot folder: every frame goes to ${f?.name ?? "the folder"}`, "folder.badge.gearshape");
      }
    },
    async shootRestoreOffer({ accept }) {
      const shoot = requireShoot();
      const offer = shoot.state.restoreOffer;
      shoot.state.restoreOffer = null;
      if (accept && offer) await backend.shootSetLook({ look: offer.look });
      emit("shoot:started", shoot.state);
    },
    async shootImportFiles({ paths }) {
      const shoot = requireShoot();
      for (let i = 0; i < paths.length; i++) {
        window.setTimeout(() => state.shoot === shoot && ingestFrame(shoot, "ftp"), i * 300);
      }
      return ok({ imported: paths.length });
    },
    async shootDeleteCapture({ captureId }) {
      const shoot = requireShoot();
      shoot.state.items = shoot.state.items.filter((i) => i.id !== captureId);
      state.captures.delete(captureId);
      state.order = state.order.filter((x) => x !== captureId);
      emit("capture:removed", { id: captureId, sessionId: shoot.state.session.id });
      if (shoot.state.selectedItemId === captureId) {
        shoot.state.selectedItemId = shoot.state.items.filter((i) => i.state.kind === "ready").at(-1)?.id ?? null;
        emit("shoot:selection", { captureId: shoot.state.selectedItemId });
      }
      libraryChanged("delete");
    },
    async shootReconnect() {
      const shoot = requireShoot();
      const strategy = shoot.state.reconnect;
      if (strategy.kind === "nothingToDo" || strategy.kind === "startFresh") return ok(shoot.state);
      setStatus(shoot, { kind: "reconnecting" });
      state.connectAbort = false;
      await wait(strategy.kind === "waitForUsbDevice" ? 1800 : 1400);
      if (state.connectAbort) {
        setStatus(shoot, { kind: "disconnected", reason: "Reconnect cancelled" });
        throw new MockError("cancelled", "Reconnect cancelled");
      }
      if (strategy.kind === "retryHost" && !/^192\.168\./.test(strategy.host)) {
        setStatus(shoot, { kind: "disconnected", reason: `Nothing answered at ${strategy.host}` });
        throw new MockError("connectFailed", `Nothing answered at ${strategy.host}:${strategy.port}.`);
      }
      setStatus(shoot, { kind: "ready" });
      if (shoot.state.identity) toast(`Reconnected to ${cameraDisplayName(shoot.state.identity)}`, "checkmark.circle");
      return ok(shoot.state);
    },
    async shootReconnectCancel() {
      state.connectAbort = true;
      await wait(5);
    },
    async shootEnd() {
      stopShoot(true);
      await wait(80);
    },

    // Library
    async librarySources() {
      const all = state.collections;
      const countsMap: Record<string, number> = {};
      const c = ctx();
      for (const col of all) {
        const items = sourceItems({ kind: "collection", id: col.id }).filter((i) => i.state.kind === "ready");
        countsMap[sourceKey({ kind: "collection", id: col.id })] = col.kind === "smart" ? items.filter((i) => matches(col.rule ?? {}, i, c)).length : items.length;
      }
      const cameraIds = new Map<string, CameraIdentity>();
      for (const s of state.sessions) if (s.camera) cameraIds.set(s.camera.id, s.camera);
      for (const s of state.sessions) countsMap[sourceKey({ kind: "session", id: s.id })] = allCaptures().filter((x) => x.sessionId === s.id && x.state.kind === "ready").length;
      for (const cam of cameraIds.values()) countsMap[sourceKey({ kind: "camera", id: cam.id })] = allCaptures().filter((x) => x.cameraId === cam.id && x.state.kind === "ready").length;
      const sorted = (list: Collection[]) => [...list].sort((a, b) => a.sortOrder - b.sortOrder);
      return ok({
        builtIns: sorted(all.filter((x) => x.isBuiltIn)),
        pinned: sorted(all.filter((x) => x.isPinned)),
        manual: sorted(all.filter((x) => !x.isBuiltIn && x.kind === "manual")),
        smart: sorted(all.filter((x) => !x.isBuiltIn && x.kind === "smart")),
        sessions: [...state.sessions].sort((a, b) => b.createdAt.localeCompare(a.createdAt)),
        cameras: [...cameraIds.values()],
        counts: countsMap,
      });
    },
    async libraryQuery({ query: q }) {
      const items = sortCaptures(query(q.source, q.filter), q.sort);
      return ok({ items: items.slice(q.offset, q.offset + q.limit), total: items.length }, 40);
    },
    libraryPreviewCount: ({ filter }) => ok(allCaptures().filter((c) => matches(filter, c, ctx())).length),
    async captureDetails({ id }) {
      const c = capture(id);
      if (!c) throw new MockError("notFound", "Capture not found.");
      const cam = c.cameraId ? state.sessions.find((s) => s.camera?.id === c.cameraId)?.camera : null;
      return ok({
        id,
        tags: [...tagsOf(id)].sort(),
        collectionIds: state.collections.filter((col) => col.kind === "manual" && state.members.get(col.id)?.has(id)).map((col) => col.id),
        exportHistory: state.history.get(id) ?? [],
        exif: c.kind === "video" ? null : {
          make: cam?.manufacturer ?? null, model: cam?.model ?? null, lens: cam?.vendor === "canon" ? "RF24-70mm F2.8 L IS USM" : cam?.vendor === "sony" ? "FE 85mm F1.4 GM" : null,
          exposureLine: [c.exposure?.shutter, c.exposure?.aperture, c.exposure?.iso ? `ISO ${c.exposure.iso}` : null].filter(Boolean).join("  ") || null,
          dateTimeOriginal: c.capturedAt,
        },
      });
    },
    async tagsSuggest({ prefix }) {
      const p = normalizeTag(prefix);
      const all = new Set<string>();
      state.tags.forEach((set) => set.forEach((t) => all.add(t)));
      return ok([...all].filter((t) => t.startsWith(p)).sort().slice(0, 12));
    },
    async reviewRate({ ids, stars }) {
      if (!ids.length) throw new MockError("nothingSelected", "Nothing selected.");
      const items = withPairs(ids);
      const before = new Map(items.map((i) => [i.id, i.rating] as const));
      const after = Math.max(0, Math.min(5, stars));
      setField(items, "rating", after);
      push({
        title: after === 0 ? "Clear rating" : `Rate ${after}★`, count: ids.length,
        undo: () => { setField(items, "rating", before); changed([...before.keys()]); },
        redo: () => { setField(items, "rating", after); changed([...before.keys()]); },
      });
      changed(items.map((i) => i.id));
      return ok(undoState(), 10);
    },
    async reviewFlag({ ids, flag }) {
      if (!ids.length) throw new MockError("nothingSelected", "Nothing selected.");
      const items = withPairs(ids);
      const before = new Map(items.map((i) => [i.id, i.flag] as const));
      setField(items, "flag", flag);
      push({
        title: flag === "none" ? "Unflag" : flag === "pick" ? "Pick" : "Reject", count: ids.length,
        undo: () => { setField(items, "flag", before); changed([...before.keys()]); },
        redo: () => { setField(items, "flag", flag); changed([...before.keys()]); },
      });
      changed(items.map((i) => i.id));
      return ok(undoState(), 10);
    },
    async reviewLabel({ ids, label }) {
      if (!ids.length) throw new MockError("nothingSelected", "Nothing selected.");
      const items = ids.map(capture).filter((c): c is CaptureItem => !!c);
      const before = new Map(items.map((i) => [i.id, i.colorLabel] as const));
      setField(items, "colorLabel", label);
      push({
        title: label === "none" ? "Clear label" : `Label ${label}`, count: ids.length,
        undo: () => { setField(items, "colorLabel", before); changed(ids); },
        redo: () => { setField(items, "colorLabel", label); changed(ids); },
      });
      changed(ids);
      return ok(undoState(), 10);
    },
    async reviewAddTags({ ids, tags }) {
      if (!ids.length) throw new MockError("nothingSelected", "Nothing selected.");
      const clean = tags.map(normalizeTag).filter(Boolean);
      const added = new Map<string, string[]>();
      for (const id of ids) {
        const set = new Set(tagsOf(id));
        const fresh = clean.filter((t) => !set.has(t));
        fresh.forEach((t) => set.add(t));
        state.tags.set(id, set);
        if (fresh.length) added.set(id, fresh);
      }
      state.recents.tags = [...new Set([...clean, ...state.recents.tags])].slice(0, 12);
      push({
        title: `Tag ${clean.map((t) => `#${t}`).join(" ")}`, count: ids.length,
        undo: () => { added.forEach((ts, id) => ts.forEach((t) => tagsOf(id).delete(t))); changed(ids); },
        redo: () => { added.forEach((ts, id) => { const s = new Set(tagsOf(id)); ts.forEach((t) => s.add(t)); state.tags.set(id, s); }); changed(ids); },
      });
      changed(ids);
      return ok(undoState(), 10);
    },
    async reviewRemoveTags({ ids, tags }) {
      const clean = tags.map(normalizeTag);
      const removed = new Map<string, string[]>();
      for (const id of ids) {
        const set = new Set(tagsOf(id));
        const gone = clean.filter((t) => set.has(t));
        gone.forEach((t) => set.delete(t));
        state.tags.set(id, set);
        if (gone.length) removed.set(id, gone);
      }
      push({
        title: "Remove tag", count: ids.length,
        undo: () => { removed.forEach((ts, id) => { const s = new Set(tagsOf(id)); ts.forEach((t) => s.add(t)); state.tags.set(id, s); }); changed(ids); },
        redo: () => { removed.forEach((ts, id) => ts.forEach((t) => tagsOf(id).delete(t))); changed(ids); },
      });
      changed(ids);
      return ok(undoState(), 10);
    },
    async reviewUndo() {
      const e = state.undo.pop();
      if (!e) return null;
      e.undo();
      state.redo.push(e);
      emit("undo:state", undoState());
      return ok({ title: e.title, count: e.count });
    },
    async reviewRedo() {
      const e = state.redo.pop();
      if (!e) return null;
      e.redo();
      state.undo.push(e);
      emit("undo:state", undoState());
      return ok({ title: e.title, count: e.count });
    },
    undoState: () => ok(undoState()),
    async collectionAddItems({ ids, collectionId }) {
      const col = collection(collectionId);
      if (!col || col.kind !== "manual") throw new MockError("notFound", "Collection not found.");
      const set = state.members.get(collectionId) ?? new Set<string>();
      const present = new Set(set);
      ids.forEach((id) => set.add(id));
      state.members.set(collectionId, set);
      state.recents.collectionIds = [collectionId, ...state.recents.collectionIds.filter((x) => x !== collectionId)].slice(0, 5);
      push({
        title: `Add to ${col.name}`, count: ids.length,
        undo: () => { ids.filter((id) => !present.has(id)).forEach((id) => set.delete(id)); changed(ids); },
        redo: () => { ids.forEach((id) => set.add(id)); changed(ids); },
      });
      changed(ids);
      return ok(undoState(), 10);
    },
    async collectionRemoveItems({ ids, collectionId }) {
      const col = collection(collectionId);
      const set = state.members.get(collectionId) ?? new Set<string>();
      const had = ids.filter((id) => set.has(id));
      had.forEach((id) => set.delete(id));
      push({
        title: `Remove from ${col?.name ?? "collection"}`, count: ids.length,
        undo: () => { had.forEach((id) => set.add(id)); changed(ids); },
        redo: () => { had.forEach((id) => set.delete(id)); changed(ids); },
      });
      changed(ids);
      return ok(undoState(), 10);
    },
    async collectionCreate({ name, ids, symbol, tint }) {
      const c: Collection = {
        id: uid("col"), name, kind: "manual", rule: null, symbol, tint, isPinned: false,
        sortOrder: state.collections.filter((x) => x.kind === "manual").length, createdAt: iso(Date.now()), updatedAt: iso(Date.now()), isBuiltIn: false,
      };
      state.collections.push(c);
      state.members.set(c.id, new Set());
      if (ids.length) await backend.collectionAddItems({ ids, collectionId: c.id });
      libraryChanged("collection");
      return ok(c);
    },
    async collectionSave({ collection: c }) {
      const i = state.collections.findIndex((x) => x.id === c.id);
      const next = { ...clone(c), updatedAt: iso(Date.now()) };
      if (i >= 0) {
        if (state.collections[i].isBuiltIn) next.rule = state.collections[i].rule;
        state.collections[i] = next;
      } else {
        next.sortOrder = state.collections.filter((x) => x.kind === next.kind && !x.isBuiltIn).length;
        state.collections.push(next);
        if (next.kind === "manual") state.members.set(next.id, new Set());
      }
      libraryChanged("collection");
      return ok(next);
    },
    async collectionDelete({ id }) {
      state.collections = state.collections.filter((c) => c.id !== id || c.isBuiltIn);
      state.members.delete(id);
      libraryChanged("collection");
      await wait(10);
    },
    async collectionTogglePin({ id }) {
      const c = collection(id);
      if (c) c.isPinned = !c.isPinned;
      libraryChanged("collection");
      await wait(10);
    },
    async collectionMove({ id, toIndex }) {
      const manual = state.collections.filter((c) => c.kind === "manual" && !c.isBuiltIn).sort((a, b) => a.sortOrder - b.sortOrder);
      const from = manual.findIndex((c) => c.id === id);
      if (from >= 0) {
        const [m] = manual.splice(from, 1);
        manual.splice(Math.max(0, Math.min(manual.length, toIndex)), 0, m);
        manual.forEach((c, i) => (c.sortOrder = i));
      }
      libraryChanged("collection");
      await wait(10);
    },
    async capturesDelete({ ids }) {
      const set = new Set(withPairs(ids).map((c) => c.id));
      set.forEach((id) => {
        const c = state.captures.get(id);
        state.captures.delete(id);
        if (c && state.shoot?.state.session.id === c.sessionId) {
          state.shoot.state.items = state.shoot.state.items.filter((i) => i.id !== id);
          emit("capture:removed", { id, sessionId: c.sessionId });
        }
      });
      state.order = state.order.filter((x) => state.captures.has(x));
      state.members.forEach((m) => set.forEach((id) => m.delete(id)));
      toast(`Moved ${set.size} file${set.size === 1 ? "" : "s"} to the Trash`, "trash");
      libraryChanged("delete");
      emit("sessions:changed", { reason: "delete" });
      await wait(20);
    },
    async libraryImport({ paths, sessionId }) {
      let s = sessionId ? session(sessionId) : undefined;
      if (!s) {
        s = sessionFor(null);
        s.name = `Import ${new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short" }).format(new Date())}`;
        s.status = "ended";
        s.transport = null;
      }
      paths.forEach((p, i) => {
        const filename = p.split("/").pop() ?? `IMPORT_${i}.JPG`;
        const id = uid("cap");
        const spec: SceneSpec = { scene: "sea", seed: 9000 + i * 7 + state.order.length, t: i / Math.max(1, paths.length - 1), tall: false, ev: 0 };
        const item: CaptureItem = {
          id, sessionId: s!.id, sequence: 9412 + i, filename, kind: filename.toLowerCase().endsWith(".arw") ? "raw" : "jpeg", bytes: 12_000_000,
          width: 6000, height: 4000, capturedAt: iso(Date.now() - 3600_000), receivedAt: iso(Date.now()), rating: 0, flag: "none", colorLabel: "none",
          state: { kind: "ready" }, pairKey: filename.replace(/\.[^.]+$/, "").toUpperCase(), source: "usb", lookId: null, exposure: null, cameraId: null, revision: 1,
        };
        state.meta.set(id, spec);
        state.captures.set(id, item);
        state.order.push(id);
        s!.captureCount += 1;
      });
      toast(`Imported ${paths.length} file${paths.length === 1 ? "" : "s"} into ${s.name}`, "square.and.arrow.down");
      emit("sessions:changed", { reason: "import" });
      libraryChanged("import");
      return ok({ imported: paths.length }, 300);
    },
    async catalogRead({ path }) {
      await wait(900);
      const r = rng(77);
      const candidates = allCaptures().filter((c) => c.state.kind === "ready" && c.kind !== "raw").slice(0, 60);
      const changes: CatalogChange[] = candidates.filter(() => r() > 0.84).slice(0, 8).map((c): CatalogChange => ({
        captureId: c.id, filename: c.filename,
        rating: r() > 0.3 ? Math.min(5, c.rating + 1 + Math.floor(r() * 2)) : null,
        flag: r() > 0.6 ? (r() > 0.3 ? "pick" : "reject") : null,
        label: r() > 0.7 ? (["red", "green", "blue"] as ColorLabel[])[Math.floor(r() * 3)] : null,
        newKeywords: r() > 0.5 ? ["selected-by-client"] : [],
      })).filter((c) => c.rating != null || c.flag != null || c.label != null || c.newKeywords.length > 0);
      return ok({
        path, name: path.split("/").pop()?.replace(/\.[^.]+$/, "") ?? "Catalog", kind: path.endsWith(".cocatalog") ? "captureOne" as const : "lightroom" as const,
        changes, unmatched: ["_MG_2231.CR2", "_MG_2232.CR2", "_MG_2240.CR2"], openElsewhere: false,
      });
    },
    async catalogApply({ changes }) {
      const groups = <K extends string | number>(key: (c: CatalogChange) => K | null) => {
        const m = new Map<K, string[]>();
        for (const c of changes) {
          const k = key(c);
          if (k != null) m.set(k, [...(m.get(k) ?? []), c.captureId]);
        }
        return m;
      };
      for (const [stars, ids] of groups((c) => c.rating)) await backend.reviewRate({ ids, stars });
      for (const [flag, ids] of groups<CaptureFlag>((c) => c.flag)) await backend.reviewFlag({ ids, flag });
      for (const [label, ids] of groups<ColorLabel>((c) => c.label)) await backend.reviewLabel({ ids, label });
      for (const c of changes.filter((x) => x.newKeywords.length)) await backend.reviewAddTags({ ids: [c.captureId], tags: c.newKeywords });
      toast(`Synced ${changes.length} frame${changes.length === 1 ? "" : "s"} from Lightroom`, "arrow.triangle.2.circlepath");
      return ok({ applied: changes.length });
    },

    // Looks
    looksList: () => ok(state.looks),
    async looksImportCube({ paths }) {
      for (const p of paths) {
        const id = uid("cube");
        const name = (p.split("/").pop() ?? "LUT").replace(/\.cube$/i, "");
        const recipe: LookRecipe = { warmth: 0.2, contrast: 0.2, saturation: -0.1, fade: 0.25 };
        state.recipes.set(id, recipe);
        state.looks.push(lookDescriptor(id, name, "Imported", recipe));
      }
      emit("looks:changed", state.looks);
      toast(paths.length ? `Added ${paths.length} look${paths.length === 1 ? "" : "s"}` : "No valid .cube files", "camera.filters");
      return ok({ added: paths.length });
    },
    async lookColorMatch({ referenceId, targetId, strength }) {
      await wait(1100);
      const ref = state.meta.get(referenceId);
      const tgt = state.meta.get(targetId);
      const warm = ((ref?.t ?? 0.5) - (tgt?.t ?? 0.5)) * 0.8;
      const recipe: LookRecipe = { warmth: warm * strength, contrast: 0.1 * strength, saturation: 0.05 * strength };
      const id = uid("match");
      const d = lookDescriptor(id, `Match ${new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" }).format(new Date())}`, "Colour match", recipe);
      state.recipes.set(id, recipe);
      state.looks.push(d);
      emit("looks:changed", state.looks);
      return ok(d);
    },

    // Export
    async exportPlan({ request }) {
      const chosen = planItems(request);
      const raw = chosen.filter((c) => c.kind === "raw").length;
      return ok({ photoCount: chosen.length - raw, rawCount: raw, previewPaths: chosen.slice(0, 3).map((c, i) => deliveredPath(c, request.options, i + 1)) } as ExportPlan, 20);
    },
    async exportEnqueue({ request }) {
      const jobs = makeJobs(request);
      if (!jobs.length) throw new MockError("nothingToExport", "Nothing to export.");
      state.jobs.unshift(...jobs);
      const scopeId = request.scope.kind === "rated" ? `rated${request.scope.min}` : request.scope.kind;
      state.exportMemory = { destination: clone(request.destination), options: clone(request.options), scope: scopeId };
      [...jobs].reverse().forEach((j) => emit("export:job", j));
      kickExports();
      return ok(jobs);
    },
    async exportAgain({ captureIds }) {
      const m = state.exportMemory;
      const scope: ExportScope = m.scope.startsWith("rated") ? { kind: "rated", min: Number(m.scope.slice(5)) || 3 } : m.scope === "picks" ? { kind: "picks" } : { kind: "all" };
      const jobs = makeJobs({ sessionId: null, captureIds, scope, destination: m.destination, options: m.options, look: null });
      if (!jobs.length) throw new MockError("nothingToExport", "Nothing to export.");
      state.jobs.unshift(...jobs);
      [...jobs].reverse().forEach((j) => emit("export:job", j));
      kickExports();
      const n = jobs.reduce((a, j) => a + j.items.filter((i) => !i.isCompanion).length, 0);
      toast(`Exporting ${n} frames to ${jobs[0].destinationName}`, "arrow.up.doc");
      return ok(jobs);
    },
    exportJobs: ({ sessionId }) => ok(state.jobs.filter((j) => !sessionId || j.sessionId === sessionId)),
    async exportPauseAll() {
      state.exportsPaused = true;
      state.jobs.filter((j) => j.status.kind === "running").forEach((j) => { j.status = { kind: "paused" }; emit("export:job", j); });
    },
    async exportResumeAll() {
      state.exportsPaused = false;
      state.jobs.filter((j) => j.status.kind === "paused").forEach((j) => { j.status = { kind: "queued" }; emit("export:job", j); });
      kickExports();
    },
    async exportRetry({ jobId }) {
      const job = state.jobs.find((j) => j.id === jobId);
      if (!job) return;
      job.items.forEach((i) => { if (i.state.kind === "failed") i.state = { kind: "pending" }; });
      job.status = { kind: "queued" };
      emit("export:job", job);
      kickExports();
    },
    async exportReveal() {
      toast("Shown in Finder (mock)", "folder");
    },
    ftpDestinationsList: () => ok(state.ftpDests),
    async ftpDestinationSave({ destination, password }) {
      const d = clone(destination);
      if (!d.id) d.id = uid("ftp");
      const i = state.ftpDests.findIndex((x) => x.id === d.id);
      if (i >= 0) state.ftpDests[i] = d;
      else state.ftpDests.push(d);
      if (password != null) state.ftpPasswords.set(d.id, password);
      return ok(d);
    },
    async ftpDestinationDelete({ id }) {
      state.ftpDests = state.ftpDests.filter((d) => d.id !== id);
      state.ftpPasswords.delete(id);
    },
    async ftpDestinationTest({ destination }) {
      await wait(900);
      if (destination.host.endsWith(".local") || /^192\.168\./.test(destination.host)) return `Logged in to ${destination.host}; ${destination.remoteDirectory} is writable.`;
      throw new MockError("ftpFailed", `Failed: could not resolve ${destination.host}.`);
    },
    ftpDestinationPassword: ({ id }) => ok(state.ftpPasswords.get(id) ?? null),
    folderDestinationsList: () => ok(state.folderDests),
    async folderDestinationAdd({ path }) {
      const name = path.split("/").filter(Boolean).pop() ?? "Folder";
      const d: FolderDestination = { id: uid("fold"), name, path, kind: /capture one/i.test(path) ? "captureOneSession" : "plain" };
      state.folderDests.push(d);
      return ok(d);
    },
    async folderDestinationSetKind({ id, kind }) {
      const d = state.folderDests.find((x) => x.id === id);
      if (!d) throw new MockError("notFound", "Folder not found.");
      d.kind = kind;
      return ok(d);
    },
    async folderDestinationDelete({ id }) {
      state.folderDests = state.folderDests.filter((d) => d.id !== id);
    },
  };

  // Debug hooks for trying the reconnect flow in a browser.
  (window as unknown as { __tetherMock: unknown }).__tetherMock = {
    disconnect: simulateDisconnect,
    state,
  };
  (backend as Backend & { simulateDisconnect?: () => void }).simulateDisconnect = simulateDisconnect;

  return backend;
}

