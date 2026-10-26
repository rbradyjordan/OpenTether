import type {
  CameraIdentity, CaptureFlag, CaptureItem, Collection, ColorLabel, ExportHistoryEntry, FolderDestination, FtpDestination,
  LookDescriptor, MediaKind, RoutingRules, SessionTemplate, ShootSession, TransportKind, CameraVendor,
} from "../types";
import { Cap } from "../types";
import type { LookRecipe, Scene, SceneSpec } from "./images";
import { rng } from "./images";

export const DAY = 86_400_000;
export const iso = (ms: number) => new Date(ms).toISOString();

let counter = 0;
export function uid(prefix = "id"): string {
  counter += 1;
  return `${prefix}-${Date.now().toString(36)}-${counter.toString(36)}-${Math.floor(Math.random() * 1e6).toString(36)}`;
}

export const defaultRouting = (): RoutingRules => ({
  jpeg: "photos", raw: "files", video: "files", autoExportPicks: false, ftpDestinationId: null, liveFolderId: null,
});

const FULL = Cap.remoteCapture | Cap.liveView | Cap.propertyControl | Cap.autofocus | Cap.touchAutofocus | Cap.rating
  | Cap.eventPush | Cap.thumbnails | Cap.partialTransfer | Cap.sdramCapture | Cap.cardCapture;

export function camera(vendor: CameraVendor, model: string, serial: string, transport: TransportKind, caps = FULL): CameraIdentity {
  const manufacturer: Record<string, string> = {
    canon: "Canon Inc.", sony: "Sony Corporation", nikon: "Nikon Corporation", fujifilm: "FUJIFILM", ricoh: "RICOH IMAGING", leica: "Leica Camera AG",
  };
  return {
    id: `${vendor}-${serial}`, vendor, manufacturer: manufacturer[vendor] ?? vendor, model, serialNumber: serial,
    firmware: "1.8.1", transport, capabilities: caps,
  };
}

export const CAMERAS = {
  r5: camera("canon", "Canon EOS R5", "032021000417", "usb"),
  a7iv: camera("sony", "ILCE-7M4", "5402871", "usb"),
  xt5: camera("fujifilm", "X-T5", "4CB10342", "ptpip", FULL & ~Cap.touchAutofocus),
  z8: camera("nikon", "Z 8", "3008812", "usb"),
  gr3: camera("ricoh", "GR III", "1407021", "ricohHTTP", Cap.remoteCapture | Cap.propertyControl | Cap.thumbnails),
};

/** Filename stem and extensions per vendor. */
export function filenameFor(vendor: CameraVendor | null, seq: number, kind: MediaKind): string {
  const n4 = String(seq).padStart(4, "0");
  const raw: Record<string, [string, string]> = {
    canon: [`IMG_${n4}`, "CR3"], sony: [`DSC0${n4}`, "ARW"], nikon: [`DSC_${n4}`, "NEF"], fujifilm: [`DSCF${n4}`, "RAF"],
    ricoh: [`R00${String(seq).padStart(5, "0")}`, "DNG"],
  };
  const [stem, ext] = vendor ? raw[vendor] ?? [`IMG_${n4}`, "DNG"] : [`DEMO_${n4}`, "DNG"];
  return `${stem}.${kind === "raw" ? ext : "JPG"}`;
}

export interface Built {
  sessions: ShootSession[];
  captures: CaptureItem[];
  meta: Map<string, SceneSpec>;
  tags: Map<string, Set<string>>;
  history: Map<string, ExportHistoryEntry[]>;
}

interface SessionSeed {
  name: string;
  daysAgo: number;
  camera: CameraIdentity | null;
  transport: TransportKind;
  scene: Scene | Scene[];
  frames: number;
  pairs: boolean;
  status: ShootSession["status"];
  lookId: string | null;
  tags: string[];
  workflowTag: string | null;
  host?: string;
}

const SEEDS: SessionSeed[] = [
  { name: "Lookbook SS27 · Studio 4", daysAgo: 3, camera: CAMERAS.r5, transport: "usb", scene: "portrait", frames: 12, pairs: true, status: "ended", lookId: "ot.portrait", tags: ["lookbook", "studio"], workflowTag: "maison-ren" },
  { name: "Harbour sunrise", daysAgo: 9, camera: CAMERAS.xt5, transport: "ptpip", scene: "sea", frames: 18, pairs: false, status: "ended", lookId: "ot.golden", tags: ["harbour"], workflowTag: null, host: "192.168.0.1" },
  { name: "Headshots · Acme Corp", daysAgo: 1, camera: CAMERAS.a7iv, transport: "usb", scene: "portrait", frames: 22, pairs: false, status: "ended", lookId: "ot.studio", tags: ["headshots", "acme"], workflowTag: "acme" },
  { name: "Ceramics catalogue", daysAgo: 20, camera: CAMERAS.z8, transport: "usb", scene: "product", frames: 10, pairs: true, status: "ended", lookId: null, tags: ["product", "ceramics"], workflowTag: "atelier-oku" },
  { name: "City at dusk", daysAgo: 0.3, camera: CAMERAS.gr3, transport: "ricohHTTP", scene: "city", frames: 14, pairs: false, status: "ended", lookId: "ot.tealorange", tags: ["street"], workflowTag: null, host: "192.168.0.1" },
  { name: "Wedding · Hill House", daysAgo: 0.08, camera: CAMERAS.r5, transport: "ptpip", scene: ["landscape", "portrait"], frames: 10, pairs: false, status: "interrupted", lookId: "ot.film", tags: ["wedding"], workflowTag: "hill-house", host: "192.168.1.2" },
  { name: "Market day (FTP)", daysAgo: 27, camera: null, transport: "ftpPush", scene: "landscape", frames: 8, pairs: false, status: "ended", lookId: null, tags: ["market"], workflowTag: null },
];

const RATING_WEIGHTS = [0.32, 0.12, 0.16, 0.2, 0.13, 0.07];

function pick<T>(r: () => number, list: T[]): T {
  return list[Math.floor(r() * list.length)];
}

function weightedRating(r: () => number): number {
  let x = r();
  for (let i = 0; i < RATING_WEIGHTS.length; i++) {
    x -= RATING_WEIGHTS[i];
    if (x <= 0) return i;
  }
  return 0;
}

export function exposureFor(r: () => number, scene: Scene) {
  const shutter = scene === "city" ? pick(r, ["1/30", "1/60", "1/15"]) : pick(r, ["1/125", "1/160", "1/200", "1/250", "1/500"]);
  const aperture = scene === "product" ? pick(r, ["ƒ/8", "ƒ/11"]) : pick(r, ["ƒ/2.8", "ƒ/4", "ƒ/5.6", "ƒ/1.8"]);
  const iso = scene === "city" ? pick(r, ["1600", "3200"]) : pick(r, ["100", "200", "400"]);
  return { shutter, aperture, iso, compensation: pick(r, ["0", "0", "+0.3", "-0.7"]), whiteBalance: pick(r, ["Auto", "Daylight", "5600K"]) };
}

export function buildLibrary(now: number): Built {
  const sessions: ShootSession[] = [];
  const captures: CaptureItem[] = [];
  const meta = new Map<string, SceneSpec>();
  const tags = new Map<string, Set<string>>();
  const history = new Map<string, ExportHistoryEntry[]>();
  SEEDS.forEach((s, si) => {
    const r = rng(1000 + si * 97);
    const created = now - s.daysAgo * DAY;
    const sessionId = `session-${si + 1}`;
    const session: ShootSession = {
      id: sessionId, name: s.name, createdAt: iso(created), endedAt: s.status === "ended" ? iso(created + 2.5 * 3600_000) : null,
      status: s.status, camera: s.camera, transport: s.transport, lastHost: s.host ?? null, destination: "both",
      routing: defaultRouting(), lookId: s.lookId, lookStrength: 1, showNewestCapture: true, workflowTag: s.workflowTag, captureCount: 0,
    };
    let seq = 100 + si * 40;
    for (let f = 0; f < s.frames; f++) {
      seq += 1;
      const scene = Array.isArray(s.scene) ? s.scene[f % s.scene.length] : s.scene;
      const spec: SceneSpec = { scene, seed: si * 1000 + f * 17 + 3, t: s.frames > 1 ? f / (s.frames - 1) : 0.3, tall: scene === "portrait" && r() > 0.35, ev: (r() - 0.5) * 0.8 };
      const rating = weightedRating(r);
      const flagRoll = r();
      const flag: CaptureFlag = rating >= 4 && flagRoll > 0.35 ? "pick" : rating <= 1 && flagRoll > 0.7 ? "reject" : "none";
      const label: ColorLabel = r() > 0.82 ? pick(r, ["red", "yellow", "green", "blue", "purple"] as ColorLabel[]) : "none";
      const at = created + f * 95_000 + Math.floor(r() * 30_000);
      const exposure = exposureFor(r, scene);
      const kinds: MediaKind[] = s.pairs ? ["raw", "jpeg"] : ["jpeg"];
      for (const kind of kinds) {
        const filename = filenameFor(s.camera?.vendor ?? (s.transport === "ftpPush" ? "fujifilm" : null), seq, kind);
        const id = `cap-${si + 1}-${f + 1}-${kind}`;
        const long = kind === "raw" ? 8192 : 6000;
        const c: CaptureItem = {
          id, sessionId, sequence: seq, filename, kind,
          bytes: kind === "raw" ? 42_000_000 + Math.floor(r() * 18_000_000) : 9_000_000 + Math.floor(r() * 7_000_000),
          width: spec.tall ? Math.round((long * 2) / 3) : long, height: spec.tall ? long : Math.round((long * 2) / 3),
          capturedAt: iso(at), receivedAt: iso(at + 1800), rating, flag, colorLabel: label, state: { kind: "ready" },
          pairKey: filename.replace(/\.[^.]+$/, "").toUpperCase(), source: s.transport, lookId: s.lookId,
          exposure, cameraId: s.camera?.id ?? null, revision: 1,
        };
        captures.push(c);
        meta.set(id, spec);
        const t = new Set(s.tags.filter(() => r() > 0.25));
        if (rating >= 4 && r() > 0.5) t.add("hero");
        if (scene === "portrait" && r() > 0.7) t.add("smile");
        tags.set(id, t);
        if (flag === "pick" && si % 2 === 0) {
          history.set(id, [{ destination: si === 2 ? "ftp" : "photos", at: iso(created + 4 * 3600_000), remoteId: null }]);
        }
      }
    }
    session.captureCount = captures.filter((c) => c.sessionId === sessionId).length;
    sessions.push(session);
  });
  sessions.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  return { sessions, captures, meta, tags, history };
}

const builtIn = (id: string, name: string, symbol: string, rule: Collection["rule"], order: number): Collection => ({
  id, name, kind: "smart", rule, symbol, tint: "none", isPinned: false, sortOrder: order, createdAt: iso(0), updatedAt: iso(0), isBuiltIn: true,
});

export function buildCollections(captures: CaptureItem[], now: number): { collections: Collection[]; members: Map<string, Set<string>> } {
  const collections: Collection[] = [
    builtIn("builtin.all", "All photos", "photo.on.rectangle", {}, 0),
    builtIn("builtin.picks", "Picks", "flag.fill", { flags: ["pick"] }, 1),
    builtIn("builtin.5", "Five stars", "star.fill", { minRating: 5 }, 2),
    builtIn("builtin.unrated", "Unrated", "circle.dashed", { maxRating: 0, flags: ["none"] }, 3),
    builtIn("builtin.today", "Today", "sun.max", { dateRange: { kind: "today" } }, 4),
    builtIn("builtin.rejects", "Rejects", "xmark.bin", { flags: ["reject"] }, 5),
    { id: "col-selects", name: "Client selects", kind: "manual", rule: null, symbol: "star", tint: "blue", isPinned: true, sortOrder: 0, createdAt: iso(now - 5 * DAY), updatedAt: iso(now - DAY), isBuiltIn: false },
    { id: "col-portfolio", name: "Portfolio", kind: "manual", rule: null, symbol: "heart", tint: "purple", isPinned: false, sortOrder: 1, createdAt: iso(now - 40 * DAY), updatedAt: iso(now - 3 * DAY), isBuiltIn: false },
    { id: "col-social", name: "Instagram queue", kind: "manual", rule: null, symbol: "sparkles.rectangle.stack", tint: "yellow", isPinned: false, sortOrder: 2, createdAt: iso(now - 12 * DAY), updatedAt: iso(now - 2 * DAY), isBuiltIn: false },
    { id: "col-keepers", name: "Keepers 4★+", kind: "smart", rule: { minRating: 4, flags: ["none", "pick"] }, symbol: "sparkles.rectangle.stack", tint: "green", isPinned: false, sortOrder: 0, createdAt: iso(now - 30 * DAY), updatedAt: iso(now - 30 * DAY), isBuiltIn: false },
    { id: "col-hero", name: "#hero frames", kind: "smart", rule: { tagsAll: ["hero"] }, symbol: "tag", tint: "none", isPinned: false, sortOrder: 1, createdAt: iso(now - 30 * DAY), updatedAt: iso(now - 30 * DAY), isBuiltIn: false },
  ];
  const members = new Map<string, Set<string>>();
  const ready = captures.filter((c) => c.kind !== "raw");
  members.set("col-selects", new Set(ready.filter((c) => c.sessionId === "session-3" && c.rating >= 3).map((c) => c.id)));
  members.set("col-portfolio", new Set(ready.filter((c) => c.rating === 5).map((c) => c.id)));
  members.set("col-social", new Set(ready.filter((c, i) => c.rating >= 3 && i % 3 === 0).map((c) => c.id)));
  return { collections, members };
}

export const LOOK_RECIPES: { id: string; name: string; recipe: LookRecipe }[] = [
  { id: "ot.natural", name: "Natural", recipe: { contrast: 0.15, saturation: 0.05 } },
  { id: "ot.portrait", name: "Warm Portrait", recipe: { warmth: 0.35, contrast: 0.1, saturation: -0.08, fade: 0.15 } },
  { id: "ot.studio", name: "Cool Studio", recipe: { warmth: -0.3, contrast: 0.25, saturation: -0.05 } },
  { id: "ot.chrome", name: "Chrome", recipe: { contrast: 0.35, saturation: -0.3, warmth: 0.05 } },
  { id: "ot.film", name: "Faded Film", recipe: { warmth: 0.15, contrast: -0.2, saturation: -0.15, fade: 0.6 } },
  { id: "ot.golden", name: "Golden Hour", recipe: { warmth: 0.6, tint: -0.1, contrast: 0.15, saturation: 0.1 } },
  { id: "ot.tealorange", name: "Teal & Orange", recipe: { contrast: 0.25, saturation: 0.05, split: 0.9 } },
  { id: "ot.matte", name: "Matte", recipe: { contrast: -0.15, saturation: -0.1, fade: 0.8 } },
  { id: "ot.mono", name: "Mono", recipe: { contrast: 0.15, saturation: -1 } },
  { id: "ot.mono.contrast", name: "Mono Contrast", recipe: { contrast: 0.55, saturation: -1 } },
];

export function lookDescriptor(id: string, name: string, family: string, recipe: LookRecipe): LookDescriptor {
  return {
    id, name, family, version: 1, size: 25,
    hint: { warmth: recipe.warmth ?? 0, contrast: recipe.contrast ?? 0, saturation: recipe.saturation ?? 0 },
  };
}

export function buildTemplates(now: number): SessionTemplate[] {
  return [
    {
      id: "tpl-headshots", name: "Headshots", symbol: "person.crop.rectangle", destination: "both",
      routing: { ...defaultRouting(), jpeg: "files" }, look: { lookId: "ot.studio", strength: 1 }, showNewestCapture: true,
      autoExportPicks: false, tags: ["headshots"], namePattern: "{date} {name}", addToCollectionId: "col-selects", useCount: 6, lastUsed: iso(now - DAY),
    },
    {
      id: "tpl-lookbook", name: "Lookbook", symbol: "camera.aperture", destination: "host",
      routing: { ...defaultRouting(), autoExportPicks: true, liveFolderId: "fold-c1" }, look: { lookId: "ot.portrait", strength: 0.8 }, showNewestCapture: true,
      autoExportPicks: true, tags: ["lookbook"], namePattern: "{name} {date} #{n}", addToCollectionId: null, useCount: 3, lastUsed: iso(now - 3 * DAY),
    },
  ];
}

export function buildFtpDestinations(): FtpDestination[] {
  return [
    { id: "ftp-nas", name: "Studio NAS", host: "nas.local", port: 21, username: "studio", security: "explicitTLS", passive: true, remoteDirectory: "/Incoming/Tether" },
    { id: "ftp-acme", name: "Acme client drop", host: "ftp.acme.example", port: 990, username: "photo", security: "implicitTLS", passive: true, remoteDirectory: "/selects" },
  ];
}

export function buildFolderDestinations(): FolderDestination[] {
  return [
    { id: "fold-c1", name: "Lookbook SS27", path: "~/Pictures/Capture One/Lookbook SS27", kind: "captureOneSession" },
    { id: "fold-lr", name: "Auto Import", path: "~/Pictures/Lightroom Auto Import", kind: "lightroomAutoImport" },
    { id: "fold-drop", name: "Client deliveries", path: "~/Dropbox/Clients/Deliveries", kind: "plain" },
  ];
}
