import { create } from "zustand";
import {
  api, errorMessage, sourceKey,
  type AppInfo, type AppSettings, type CaptureFilter, type CaptureFlag, type CaptureItem, type CaptureSort, type ColorLabel,
  type ConnectProgress, type ExportJob, type LibrarySource, type LibrarySources, type LiveViewFrame, type LookDescriptor,
  type LookStack, type SessionSummary, type ShootState, type ToastMessage, type UndoState, type PTPValue, type TetherProperty,
  type ViewState, isReady,
} from "../api";
import type { FocusIndicator, LibraryState, Modal, ModalKind, Pane, Route, StackName } from "./types";
import { withSearch } from "../lib/filter";

const PAGE = 400;

const defaultLibrary = (): LibraryState => ({
  source: { kind: "collection", id: "builtin.all" },
  filter: {},
  search: "",
  sort: "captureTimeDescending",
  columns: 4,
  stackPairs: true,
  expanded: [],
  items: [],
  total: 0,
  loading: false,
  selection: { ids: [], anchor: null },
  focusedId: null,
  inspectorOpen: typeof window === "undefined" || window.innerWidth >= 1180,
  loupeId: null,
  scrollToId: null,
});

export interface AppStore {
  ready: boolean;
  bootError: string | null;
  info: AppInfo | null;
  settings: AppSettings | null;

  pane: Pane;
  stacks: Record<StackName, Route[]>;
  modals: Modal[];
  showShoot: boolean;
  toasts: ToastMessage[];

  sessions: SessionSummary[];
  looks: LookDescriptor[];
  jobs: ExportJob[];
  undo: UndoState;
  sources: LibrarySources | null;

  shoot: ShootState | null;
  liveFrame: LiveViewFrame | null;
  liveViewStarting: boolean;
  liveViewStopping: boolean;
  unseen: number;
  reconnectSnoozed: boolean;
  reconnecting: boolean;
  reconnectError: string | null;
  focus: { point: { x: number; y: number } | null; id: number; indicator: FocusIndicator };
  connect: ConnectProgress | null;
  capturePulse: number;

  library: LibraryState;
  sessionDetail: { id: string; items: CaptureItem[] } | null;

  boot(): Promise<void>;
  updateSettings(patch: Partial<AppSettings>): Promise<void>;

  setPane(p: Pane): void;
  push(stack: StackName, r: Route): void;
  pop(stack: StackName): void;
  popTo(stack: StackName, index: number): void;
  openModal(m: Modal): void;
  closeModal(kind?: ModalKind): void;
  toast(text: string, symbol?: string, action?: ToastMessage["action"]): void;
  dismissToast(id: string): void;
  fail(e: unknown): void;

  refreshSessions(): Promise<void>;
  refreshSources(): Promise<void>;
  refreshJobs(): Promise<void>;
  refreshLooks(): Promise<void>;

  // Library
  selectSource(source: LibrarySource): Promise<void>;
  setFilter(f: CaptureFilter): void;
  setSearch(s: string): void;
  setSort(s: CaptureSort): void;
  setColumns(n: number): void;
  setStackPairs(on: boolean): void;
  toggleStack(key: string): void;
  reloadLibrary(keepScroll?: boolean): Promise<void>;
  loadMore(): Promise<void>;
  selectTile(id: string, mode: "replace" | "toggle" | "extend", ordered: string[]): void;
  setSelection(ids: string[]): void;
  clearSelection(): void;
  setFocused(id: string | null): void;
  setInspector(open: boolean): void;
  setLoupe(id: string | null): void;
  revealInSession(item: CaptureItem): void;

  // Shoot
  activate(state: ShootState): void;
  setShowShoot(on: boolean): void;
  capture(autofocus: boolean): Promise<void>;
  setProperty(property: TetherProperty, raw: PTPValue): Promise<void>;
  toggleLiveView(): Promise<void>;
  focusAt(x: number, y: number): Promise<void>;
  trackStart(x: number, y: number): Promise<void>;
  trackEnd(): Promise<void>;
  shootSelect(id: string | null): void;
  showNewest(): void;
  setFollowNewest(on: boolean): void;
  setLook(look: LookStack): void;
  endShoot(): Promise<void>;
  reconnect(): Promise<void>;
  cancelReconnect(): Promise<void>;
  snoozeReconnect(): void;
  showReconnect(): void;

  // Review (undoable, through the engine's review editor)
  rate(ids: string[], stars: number): Promise<void>;
  flag(ids: string[], flag: CaptureFlag): Promise<void>;
  label(ids: string[], label: ColorLabel): Promise<void>;
  addTags(ids: string[], tags: string[]): Promise<void>;
  removeTags(ids: string[], tags: string[]): Promise<void>;
  addToCollection(ids: string[], collectionId: string): Promise<void>;
  removeFromCollection(ids: string[], collectionId: string): Promise<void>;
  doUndo(): Promise<void>;
  doRedo(): Promise<void>;

  openSessionDetail(id: string): Promise<void>;
}

const mergeItems = (list: CaptureItem[], changed: CaptureItem[]): CaptureItem[] => {
  if (!changed.length) return list;
  const map = new Map(changed.map((c) => [c.id, c] as const));
  let touched = false;
  const out = list.map((c) => {
    const n = map.get(c.id);
    if (n) touched = true;
    return n ?? c;
  });
  return touched ? out : list;
};

let viewSaveTimer: number | null = null;
let reloadSeq = 0;
/** Event subscriptions are made once per page (StrictMode and HMR run effects twice). */
let subscribed = false;

export const useApp = create<AppStore>()((set, get) => {
  function saveView() {
    if (viewSaveTimer != null) clearTimeout(viewSaveTimer);
    viewSaveTimer = window.setTimeout(() => {
      const l = get().library;
      const v: ViewState = { filter: l.filter, sort: l.sort, columns: l.columns, stackPairs: l.stackPairs };
      api.viewStateSet({ key: sourceKey(l.source), state: v }).catch(() => undefined);
    }, 300);
  }

  function patchLibrary(p: Partial<LibraryState>) {
    set((s) => ({ library: { ...s.library, ...p } }));
  }

  function patchShoot(p: Partial<ShootState>) {
    const shoot = get().shoot;
    if (shoot) set({ shoot: { ...shoot, ...p } });
  }

  function subscribe() {
    if (subscribed) return;
    subscribed = true;
    api.on("toast", (t) => set((s) => (s.toasts.some((x) => x.id === t.id) ? {} : { toasts: [...s.toasts.slice(-3), t] })));
    api.on("undo:state", (u) => set({ undo: u }));
    api.on("sessions:changed", () => {
      get().refreshSessions();
      get().refreshSources();
    });
    api.on("library:changed", () => {
      get().refreshSources();
      get().reloadLibrary(true);
      const d = get().sessionDetail;
      if (d) get().openSessionDetail(d.id);
    });
    api.on("looks:changed", (looks) => set({ looks }));
    api.on("captures:changed", (items) => {
      set((s) => ({
        library: { ...s.library, items: mergeItems(s.library.items, items) },
        shoot: s.shoot ? { ...s.shoot, items: mergeItems(s.shoot.items, items) } : s.shoot,
        sessionDetail: s.sessionDetail ? { ...s.sessionDetail, items: mergeItems(s.sessionDetail.items, items) } : s.sessionDetail,
      }));
    });
    api.on("export:job", (job) => set((s) => {
      const i = s.jobs.findIndex((j) => j.id === job.id);
      if (i < 0) return { jobs: [job, ...s.jobs] };
      const jobs = [...s.jobs];
      jobs[i] = job;
      return { jobs };
    }));
    api.on("export:finished", () => get().refreshSources());
    api.on("connect:progress", (p) => set({ connect: p }));

    // Shoot
    api.on("shoot:started", (st) => get().activate(st));
    api.on("shoot:ended", () => {
      set({ shoot: null, showShoot: false, liveFrame: null, unseen: 0, modals: get().modals.filter((m) => !shootModal(m.kind)) });
      get().refreshSessions();
    });
    api.on("shoot:status", ({ status }) => {
      const prev = get().shoot?.status;
      patchShoot({ status });
      if (status.kind === "disconnected" && prev?.kind !== "disconnected" && !get().reconnecting) {
        const sh = get().shoot;
        if (sh && sh.reconnect.kind !== "nothingToDo") {
          get().toast(status.reason, "bolt.slash");
          set({ liveFrame: null });
          if (!get().reconnectSnoozed && get().showShoot) get().showReconnect();
        }
      }
      if (status.kind === "ready" && get().modals.some((m) => m.kind === "reconnect") && !get().reconnecting) {
        get().closeModal("reconnect");
      }
    });
    api.on("shoot:session", (session) => {
      patchShoot({ session });
      set((s) => ({ sessions: s.sessions.map((x) => (x.session.id === session.id ? { ...x, session } : x)) }));
    });
    api.on("shoot:identity", (identity) => patchShoot({ identity }));
    api.on("shoot:properties", (properties) => patchShoot({ properties }));
    api.on("shoot:look", (look) => patchShoot({ look }));
    api.on("shoot:downloads", ({ inFlight }) => patchShoot({ downloadsInFlight: inFlight }));
    api.on("shoot:selection", ({ captureId }) => {
      patchShoot({ selectedItemId: captureId });
      if (get().shoot?.session.showNewestCapture) set({ unseen: 0 });
    });
    api.on("shoot:liveview", ({ active }) => {
      patchShoot({ liveViewActive: active });
      if (!active) set({ liveFrame: null });
    });
    api.on("liveview:frame", (frame) => {
      if (get().shoot?.liveViewActive) set({ liveFrame: frame });
    });
    api.on("capture:added", (item) => {
      const sh = get().shoot;
      if (!sh || sh.session.id !== item.sessionId) return;
      if (sh.items.some((i) => i.id === item.id)) return;
      patchShoot({ items: [...sh.items, item] });
    });
    api.on("capture:updated", (item) => {
      const sh = get().shoot;
      if (!sh || sh.session.id !== item.sessionId) return;
      const prev = sh.items.find((i) => i.id === item.id);
      const becameReady = isReady(item) && !!prev && !isReady(prev);
      patchShoot({ items: prev ? sh.items.map((i) => (i.id === item.id ? item : i)) : [...sh.items, item] });
      if (becameReady && !sh.session.showNewestCapture && item.kind !== "raw") {
        set((s) => ({ unseen: s.unseen + 1 }));
        get().toast(`New frame ${item.filename}`, "photo.badge.plus", { title: "Show", command: "shoot.showNewest" });
      }
    });
    api.on("capture:removed", ({ id }) => {
      const sh = get().shoot;
      if (sh) patchShoot({ items: sh.items.filter((i) => i.id !== id) });
    });
  }

  return {
    ready: false,
    bootError: null,
    info: null,
    settings: null,
    pane: "library",
    stacks: { connect: [{ kind: "connectHub" }], sessions: [{ kind: "sessionsHome" }], settings: [{ kind: "settings" }] },
    modals: [],
    showShoot: false,
    toasts: [],
    sessions: [],
    looks: [],
    jobs: [],
    undo: { undoTitle: null, redoTitle: null },
    sources: null,
    shoot: null,
    liveFrame: null,
    liveViewStarting: false,
    liveViewStopping: false,
    unseen: 0,
    reconnectSnoozed: false,
    reconnecting: false,
    reconnectError: null,
    focus: { point: null, id: 0, indicator: "focusing" },
    connect: null,
    capturePulse: 0,
    library: defaultLibrary(),
    sessionDetail: null,

    async boot() {
      try {
        subscribe();
        const [info, settings, sessions, looks, jobs, undo, shoot, last] = await Promise.all([
          api.appInfo(), api.settingsGet(), api.sessionsList(), api.looksList(), api.exportJobs({ sessionId: null }), api.undoState(),
          api.shootState(), api.lastSourceGet(),
        ]);
        set({ info, settings, sessions, looks, jobs, undo, shoot, ready: true });
        if (shoot) set({ showShoot: false });
        await get().refreshSources();
        let source: LibrarySource = { kind: "collection", id: "builtin.all" };
        if (last) {
          const [kind, ...rest] = last.split(":");
          const id = rest.join(":");
          if ((kind === "collection" || kind === "session" || kind === "camera") && id) source = { kind, id };
        }
        await get().selectSource(source);
      } catch (e) {
        set({ bootError: errorMessage(e), ready: true });
      }
    },

    async updateSettings(patch) {
      try {
        const settings = await api.settingsUpdate({ patch });
        set({ settings });
      } catch (e) {
        get().fail(e);
      }
    },

    setPane(pane) {
      set({ pane });
    },
    push(stack, r) {
      set((s) => ({ stacks: { ...s.stacks, [stack]: [...s.stacks[stack], r] } }));
    },
    pop(stack) {
      set((s) => ({ stacks: { ...s.stacks, [stack]: s.stacks[stack].length > 1 ? s.stacks[stack].slice(0, -1) : s.stacks[stack] } }));
    },
    popTo(stack, index) {
      set((s) => ({ stacks: { ...s.stacks, [stack]: s.stacks[stack].slice(0, Math.max(1, index + 1)) } }));
    },
    openModal(m) {
      set((s) => ({ modals: [...s.modals.filter((x) => x.kind !== m.kind), m] }));
    },
    closeModal(kind) {
      set((s) => {
        if (!kind) return { modals: s.modals.slice(0, -1) };
        const i = s.modals.map((m) => m.kind).lastIndexOf(kind);
        if (i < 0) return {};
        const modals = [...s.modals];
        modals.splice(i, 1);
        return { modals };
      });
      if (kind === "reconnect") get().snoozeReconnect();
    },
    toast(text, symbol = "info.circle", action) {
      const t: ToastMessage = { id: `t${Date.now()}${Math.random()}`, text, symbol, action: action ?? null };
      set((s) => ({ toasts: [...s.toasts.slice(-3), t] }));
    },
    dismissToast(id) {
      set((s) => ({ toasts: s.toasts.filter((t) => t.id !== id) }));
    },
    fail(e) {
      get().toast(errorMessage(e), "exclamationmark.triangle");
    },

    async refreshSessions() {
      try {
        set({ sessions: await api.sessionsList() });
      } catch (e) {
        get().fail(e);
      }
    },
    async refreshSources() {
      try {
        set({ sources: await api.librarySources() });
      } catch (e) {
        get().fail(e);
      }
    },
    async refreshJobs() {
      set({ jobs: await api.exportJobs({ sessionId: null }) });
    },
    async refreshLooks() {
      set({ looks: await api.looksList() });
    },

    // MARK: Library

    async selectSource(source) {
      const v = await api.viewStateGet({ key: sourceKey(source) }).catch(() => null);
      const l = get().library;
      patchLibrary({
        source,
        filter: v?.filter ?? {},
        sort: v?.sort ?? l.sort,
        columns: v?.columns ?? l.columns,
        stackPairs: v?.stackPairs ?? l.stackPairs,
        selection: { ids: [], anchor: null },
        focusedId: null,
        items: [],
        total: 0,
        expanded: [],
      });
      set({ pane: "library" });
      saveView();
      await get().reloadLibrary();
    },
    setFilter(filter) {
      patchLibrary({ filter });
      saveView();
      get().reloadLibrary();
    },
    setSearch(search) {
      patchLibrary({ search });
      get().reloadLibrary();
    },
    setSort(sort) {
      patchLibrary({ sort });
      saveView();
      get().reloadLibrary();
    },
    setColumns(n) {
      patchLibrary({ columns: Math.max(2, Math.min(10, n)) });
      saveView();
    },
    setStackPairs(on) {
      patchLibrary({ stackPairs: on });
      saveView();
    },
    toggleStack(key) {
      const e = get().library.expanded;
      patchLibrary({ expanded: e.includes(key) ? e.filter((x) => x !== key) : [...e, key] });
    },
    async reloadLibrary(keepScroll = false) {
      const seq = ++reloadSeq;
      const l = get().library;
      if (!keepScroll) patchLibrary({ loading: true });
      try {
        const limit = Math.max(PAGE, keepScroll ? l.items.length : 0);
        const page = await api.libraryQuery({ query: { source: l.source, filter: withSearch(l.filter, l.search), sort: l.sort, offset: 0, limit } });
        if (seq !== reloadSeq) return;
        const ids = new Set(page.items.map((i) => i.id));
        const cur = get().library;
        patchLibrary({
          items: page.items,
          total: page.total,
          loading: false,
          selection: { ids: cur.selection.ids.filter((id) => ids.has(id)), anchor: cur.selection.anchor && ids.has(cur.selection.anchor) ? cur.selection.anchor : null },
          focusedId: cur.focusedId && ids.has(cur.focusedId) ? cur.focusedId : null,
        });
      } catch (e) {
        patchLibrary({ loading: false });
        get().fail(e);
      }
    },
    async loadMore() {
      const l = get().library;
      if (l.loading || l.items.length >= l.total) return;
      patchLibrary({ loading: true });
      try {
        const page = await api.libraryQuery({ query: { source: l.source, filter: withSearch(l.filter, l.search), sort: l.sort, offset: l.items.length, limit: PAGE } });
        patchLibrary({ items: [...get().library.items, ...page.items], total: page.total, loading: false });
      } catch (e) {
        patchLibrary({ loading: false });
        get().fail(e);
      }
    },
    selectTile(id, mode, ordered) {
      const sel = get().library.selection;
      let ids: string[];
      let anchor: string | null = id;
      if (mode === "replace") ids = [id];
      else if (mode === "toggle") ids = sel.ids.includes(id) ? sel.ids.filter((x) => x !== id) : [...sel.ids, id];
      else {
        const a = sel.anchor ? ordered.indexOf(sel.anchor) : -1;
        const b = ordered.indexOf(id);
        if (a < 0 || b < 0) ids = [id];
        else {
          ids = [...sel.ids];
          for (const x of ordered.slice(Math.min(a, b), Math.max(a, b) + 1)) if (!ids.includes(x)) ids.push(x);
          anchor = sel.anchor;
        }
      }
      patchLibrary({ selection: { ids, anchor }, focusedId: id });
    },
    setSelection(ids) {
      patchLibrary({ selection: { ids, anchor: ids.at(-1) ?? null } });
    },
    clearSelection() {
      patchLibrary({ selection: { ids: [], anchor: null } });
    },
    setFocused(id) {
      patchLibrary({ focusedId: id });
    },
    setInspector(open) {
      patchLibrary({ inspectorOpen: open });
    },
    setLoupe(id) {
      patchLibrary({ loupeId: id, focusedId: id ?? get().library.focusedId, scrollToId: id ?? get().library.loupeId });
      if (id) get().openModal({ kind: "loupe", origin: "library" });
    },
    revealInSession(item) {
      get().closeModal("loupe");
      get().selectSource({ kind: "session", id: item.sessionId }).then(() => {
        patchLibrary({ focusedId: item.id, scrollToId: item.id, selection: { ids: [item.id], anchor: item.id } });
      });
    },

    // MARK: Shoot

    activate(state) {
      const same = get().shoot?.session.id === state.session.id;
      set({
        shoot: state,
        showShoot: true,
        connect: null,
        unseen: same ? get().unseen : 0,
        reconnectSnoozed: false,
        reconnectError: null,
        liveFrame: null,
      });
      if (state.status.kind === "disconnected" && state.reconnect.kind !== "nothingToDo") get().showReconnect();
      get().refreshSessions();
    },
    setShowShoot(on) {
      set({ showShoot: on && !!get().shoot });
    },
    async capture(autofocus) {
      const sh = get().shoot;
      if (!sh) return;
      set((s) => ({ capturePulse: s.capturePulse + 1 }));
      try {
        await api.shootCapture({ autofocus });
      } catch (e) {
        get().fail(e);
      }
    },
    async setProperty(property, raw) {
      try {
        await api.shootSetProperty({ property, raw });
      } catch (e) {
        get().toast(`${property}: ${errorMessage(e)}`, "exclamationmark.triangle");
      }
    },
    async toggleLiveView() {
      const sh = get().shoot;
      if (!sh || get().liveViewStarting || get().liveViewStopping) return;
      if (sh.liveViewActive) {
        set({ liveViewStopping: true, liveFrame: null });
        patchShoot({ liveViewActive: false });
        try {
          await api.shootLiveViewStop();
        } finally {
          set({ liveViewStopping: false });
        }
      } else {
        set({ liveViewStarting: true });
        try {
          await api.shootLiveViewStart();
          patchShoot({ liveViewActive: true });
        } catch (e) {
          get().fail(e);
        } finally {
          set({ liveViewStarting: false });
        }
      }
    },
    async focusAt(x, y) {
      const id = get().focus.id + 1;
      set({ focus: { point: { x, y }, id, indicator: "focusing" } });
      try {
        const result = await api.shootFocus({ x, y });
        if (get().focus.id === id) set({ focus: { ...get().focus, indicator: result } });
      } catch (e) {
        if (get().focus.id === id) set({ focus: { ...get().focus, indicator: "unconfirmed" } });
        get().toast(`Focus: ${errorMessage(e)}`, "exclamationmark.triangle");
      }
    },
    async trackStart(x, y) {
      const id = get().focus.id + 1;
      set({ focus: { point: { x, y }, id, indicator: "tracking" } });
      try {
        await api.shootFocusTrackStart({ x, y });
      } catch (e) {
        get().fail(e);
      }
    },
    async trackEnd() {
      await api.shootFocusTrackStop().catch(() => undefined);
      if (get().focus.indicator === "tracking") set({ focus: { ...get().focus, indicator: "unconfirmed" } });
    },
    shootSelect(id) {
      patchShoot({ selectedItemId: id });
      api.shootSelect({ captureId: id }).catch((e) => get().fail(e));
    },
    showNewest() {
      const sh = get().shoot;
      set({ unseen: 0 });
      const latest = sh?.items.filter((i) => isReady(i) && i.kind !== "raw").at(-1) ?? sh?.items.filter(isReady).at(-1);
      if (latest) get().shootSelect(latest.id);
    },
    setFollowNewest(on) {
      const sh = get().shoot;
      if (!sh) return;
      patchShoot({ session: { ...sh.session, showNewestCapture: on } });
      if (on) set({ unseen: 0 });
      api.shootSetFollowNewest({ on }).catch((e) => get().fail(e));
    },
    setLook(look) {
      patchShoot({ look });
      api.shootSetLook({ look }).catch((e) => get().fail(e));
    },
    async endShoot() {
      try {
        await api.shootEnd();
      } catch (e) {
        get().fail(e);
      }
      set({ shoot: null, showShoot: false, liveFrame: null, modals: get().modals.filter((m) => !shootModal(m.kind)) });
      get().refreshSessions();
      get().refreshSources();
    },
    async reconnect() {
      if (get().reconnecting) return;
      set({ reconnecting: true, reconnectError: null });
      try {
        const st = await api.shootReconnect();
        set({ shoot: st, reconnectSnoozed: false });
        set((s) => ({ modals: s.modals.filter((m) => m.kind !== "reconnect") }));
      } catch (e) {
        set({ reconnectError: errorMessage(e) });
      } finally {
        set({ reconnecting: false });
      }
    },
    async cancelReconnect() {
      await api.shootReconnectCancel().catch(() => undefined);
      set({ reconnecting: false });
    },
    snoozeReconnect() {
      const st = get().shoot?.status.kind;
      if (st === "disconnected" || st === "reconnecting") set({ reconnectSnoozed: true });
    },
    showReconnect() {
      set({ reconnectSnoozed: false });
      set((s) => ({ modals: [...s.modals.filter((m) => m.kind !== "reconnect"), { kind: "reconnect" }] }));
    },

    // MARK: Review

    async rate(ids, stars) {
      if (!ids.length) return;
      optimistic(ids, (c) => ({ ...c, rating: stars }));
      try {
        set({ undo: await api.reviewRate({ ids, stars }) });
      } catch (e) {
        get().fail(e);
      }
    },
    async flag(ids, flag) {
      if (!ids.length) return;
      optimistic(ids, (c) => ({ ...c, flag }));
      try {
        set({ undo: await api.reviewFlag({ ids, flag }) });
      } catch (e) {
        get().fail(e);
      }
    },
    async label(ids, label) {
      if (!ids.length) return;
      optimistic(ids, (c) => ({ ...c, colorLabel: label }));
      try {
        set({ undo: await api.reviewLabel({ ids, label }) });
      } catch (e) {
        get().fail(e);
      }
    },
    async addTags(ids, tags) {
      try {
        set({ undo: await api.reviewAddTags({ ids, tags }) });
      } catch (e) {
        get().fail(e);
      }
    },
    async removeTags(ids, tags) {
      try {
        set({ undo: await api.reviewRemoveTags({ ids, tags }) });
      } catch (e) {
        get().fail(e);
      }
    },
    async addToCollection(ids, collectionId) {
      try {
        set({ undo: await api.collectionAddItems({ ids, collectionId }) });
        const name = get().sources?.manual.find((c) => c.id === collectionId)?.name ?? "collection";
        get().toast(`Added ${ids.length === 1 ? "1 photo" : `${ids.length} photos`} to ${name}`, "rectangle.stack.badge.plus");
      } catch (e) {
        get().fail(e);
      }
    },
    async removeFromCollection(ids, collectionId) {
      try {
        set({ undo: await api.collectionRemoveItems({ ids, collectionId }) });
      } catch (e) {
        get().fail(e);
      }
    },
    async doUndo() {
      try {
        const r = await api.reviewUndo();
        if (r) get().toast(`Undid ${r.title}${r.count > 1 ? ` · ${r.count} photos` : ""}`, "arrow.uturn.backward");
        set({ undo: await api.undoState() });
      } catch (e) {
        get().fail(e);
      }
    },
    async doRedo() {
      try {
        const r = await api.reviewRedo();
        if (r) get().toast(`Redid ${r.title}${r.count > 1 ? ` · ${r.count} photos` : ""}`, "arrow.uturn.forward");
        set({ undo: await api.undoState() });
      } catch (e) {
        get().fail(e);
      }
    },

    async openSessionDetail(id) {
      try {
        const items = await api.sessionCaptures({ id });
        set({ sessionDetail: { id, items } });
      } catch (e) {
        get().fail(e);
      }
    },
  };

  /** Apply a review edit locally right away; the engine's captures:changed confirms it. */
  function optimistic(ids: string[], f: (c: CaptureItem) => CaptureItem) {
    const set_ = new Set(ids);
    const apply = (list: CaptureItem[]) => list.map((c) => (set_.has(c.id) ? f(c) : c));
    set((s) => ({
      library: { ...s.library, items: apply(s.library.items) },
      shoot: s.shoot ? { ...s.shoot, items: apply(s.shoot.items) } : s.shoot,
      sessionDetail: s.sessionDetail ? { ...s.sessionDetail, items: apply(s.sessionDetail.items) } : s.sessionDetail,
    }));
  }
});

/** Modals that only make sense while a shoot is open. */
export function shootModal(kind: ModalKind): boolean {
  return kind === "reconnect" || kind === "property" || kind === "looks" || kind === "colorMatch" || kind === "diagnosticsSheet";
}

// MARK: Selectors

export function displayedItem(shoot: ShootState | null): CaptureItem | null {
  if (!shoot) return null;
  const sel = shoot.items.find((i) => i.id === shoot.selectedItemId);
  if (sel) return sel;
  const ready = shoot.items.filter(isReady);
  return ready.filter((i) => i.kind !== "raw").at(-1) ?? ready.at(-1) ?? null;
}

export function readyItems(items: CaptureItem[]): CaptureItem[] {
  return items.filter(isReady);
}

/** RAW+JPEG stacks: one tile per pair with the JPEG on top. */
export interface CaptureStack {
  key: string;
  items: CaptureItem[];
  top: CaptureItem;
}

export function stacks(items: CaptureItem[]): CaptureStack[] {
  const order: string[] = [];
  const groups = new Map<string, CaptureItem[]>();
  for (const i of items) {
    const k = `${i.sessionId}/${i.pairKey}`;
    if (!groups.has(k)) {
      order.push(k);
      groups.set(k, []);
    }
    groups.get(k)!.push(i);
  }
  return order.map((key) => {
    const list = groups.get(key)!;
    return { key, items: list, top: list.find((i) => i.kind !== "raw") ?? list[0] };
  });
}

/** The tiles the grid shows, in order (collapsed pairs show only the top). */
export function visibleTiles(l: LibraryState): { item: CaptureItem; stack: CaptureStack }[] {
  const out: { item: CaptureItem; stack: CaptureStack }[] = [];
  for (const st of stacks(l.items)) {
    if (l.stackPairs && !l.expanded.includes(st.key)) out.push({ item: st.top, stack: st });
    else st.items.forEach((item) => out.push({ item, stack: st }));
  }
  return out;
}

/** What review shortcuts act on in the library: the selection, else the focused tile. */
export function libraryTargets(l: LibraryState): string[] {
  if (l.selection.ids.length) return l.selection.ids;
  return l.focusedId ? [l.focusedId] : [];
}

export function inspectedItem(l: LibraryState): CaptureItem | null {
  const id = l.focusedId ?? l.selection.ids.at(-1) ?? null;
  return (id && l.items.find((i) => i.id === id)) || null;
}
