import { api, errorMessage, hasCap, Cap, type CaptureFlag, type ColorLabel, type Collection } from "../api";
import { useApp, displayedItem, visibleTiles, libraryTargets } from "../state/store";
import { available, type Command, type CommandContext } from "./catalogue";
import { withSearch } from "../lib/filter";
import { plural } from "../lib/format";

export type Surface = "library" | "shoot" | "session";

/** What the UI knows when asking which commands apply. */
export function commandContext(surface: Surface, ids: string[], collection: Collection | null = null): CommandContext {
  const s = useApp.getState();
  const shoot = s.shoot;
  return {
    selectionCount: ids.length,
    inLiveSession: surface === "shoot" && !!shoot,
    cameraCapabilities: shoot?.identity?.capabilities ?? 0,
    inCollection: surface === "library" ? collection : null,
    canUndo: !!s.undo.undoTitle,
    canRedo: !!s.undo.redoTitle,
    inShoot: surface === "shoot",
  };
}

export function commandsFor(surface: Surface, ids: string[], collection: Collection | null = null): Command[] {
  return available(commandContext(surface, ids, collection));
}

/** The collection the library is showing, when the source is one. */
export function currentCollection(): Collection | null {
  const s = useApp.getState();
  const src = s.library.source;
  if (src.kind !== "collection" || !s.sources) return null;
  const all = [...s.sources.builtIns, ...s.sources.manual, ...s.sources.smart];
  return all.find((c) => c.id === src.id) ?? null;
}

export function newCollectionDraft(kind: "manual" | "smart", rule: Collection["rule"] = null): Collection {
  const now = new Date().toISOString();
  return {
    id: `col-${Date.now().toString(36)}`, name: "", kind, rule: kind === "smart" ? rule ?? {} : null,
    symbol: kind === "smart" ? "sparkles.rectangle.stack" : "rectangle.stack", tint: "none", isPinned: false, sortOrder: 0,
    createdAt: now, updatedAt: now, isBuiltIn: false,
  };
}

/** Runs one command on `ids` from `surface`. Every menu, palette entry and shortcut ends up here. */
export async function runCommand(cmd: Command, ids: string[], surface: Surface): Promise<void> {
  const s = useApp.getState();
  const id = cmd.id;
  try {
    if (id.startsWith("rate.")) return s.rate(ids, Number(id.slice(5)));
    if (id.startsWith("flag.")) {
      const flag = id.slice(5) as CaptureFlag;
      // Flag buttons toggle: sending the active flag again clears it (shoot surface).
      return s.flag(ids, flag);
    }
    if (id.startsWith("label.")) {
      const label = id.slice(6) as ColorLabel;
      if (surface === "shoot" && ids.length === 1) {
        const cur = s.shoot?.items.find((i) => i.id === ids[0])?.colorLabel;
        return s.label(ids, cur === label ? "none" : label);
      }
      return s.label(ids, label);
    }
    switch (id) {
      case "tag.add": return s.openModal({ kind: "tags", ids });
      case "collection.add": return s.openModal({ kind: "collectionPicker", ids });
      case "collection.new": return s.openModal({ kind: "collectionEditor", draft: newCollectionDraft("manual"), pendingIds: ids });
      case "collection.remove": {
        const col = currentCollection();
        if (col) return s.removeFromCollection(ids, col.id);
        return;
      }
      case "collection.smart":
        return s.openModal({ kind: "collectionEditor", draft: newCollectionDraft("smart", withSearch(s.library.filter, s.library.search)) });
      case "export": return openExport(surface, ids);
      case "export.again": {
        const jobs = await api.exportAgain({ captureIds: ids });
        if (!jobs.length) s.toast("Nothing to export", "exclamationmark.triangle");
        return;
      }
      case "look.match": return s.openModal({ kind: "colorMatch", targetId: ids[0] ?? null });
      case "view.compare": return s.openModal({ kind: "compare", origin: surface === "shoot" ? "shoot" : surface === "session" ? "session" : "library", ids });
      case "view.client": {
        if (surface === "shoot") {
          if (ids[0]) s.shootSelect(ids[0]);
          return s.openModal({ kind: "clientReview", origin: "shoot" });
        }
        if (surface === "library" && ids[0]) useApp.setState((st) => ({ library: { ...st.library, loupeId: ids[0] } }));
        return s.openModal({ kind: "clientReview", origin: surface === "session" ? "session" : "library" });
      }
      case "select.all": return s.setSelection(visibleTiles(s.library).map((t) => t.item.id));
      case "select.picks": return s.setSelection(visibleTiles(s.library).filter((t) => t.item.flag === "pick").map((t) => t.item.id));
      case "select.invert": {
        const cur = new Set(s.library.selection.ids);
        return s.setSelection(visibleTiles(s.library).map((t) => t.item.id).filter((x) => !cur.has(x)));
      }
      case "undo": return s.doUndo();
      case "redo": return s.doRedo();
      case "camera.capture": return s.capture(true);
      case "camera.liveview": return s.toggleLiveView();
      case "delete":
        return s.openModal({
          kind: "confirm",
          title: `Move ${plural(ids.length, "photo")} to the Trash?`,
          message: "The files leave the library and the session. RAW+JPEG twins go with them.",
          confirmTitle: "Move to Trash",
          destructive: true,
          onConfirm: () => {
            api.capturesDelete({ ids }).catch((e) => useApp.getState().fail(e));
            useApp.getState().clearSelection();
          },
        });
      case "session.template": {
        const sid = s.shoot?.session.id;
        if (!sid) return;
        const template = await api.templateFromSession({ sessionId: sid });
        return s.openModal({ kind: "templateEditor", template, isNew: true });
      }
      case "session.end":
        return s.openModal({
          kind: "confirm",
          title: "End this session?",
          message: "The camera link is closed. Captures stay in the session and can be exported later.",
          confirmTitle: "End session",
          cancelTitle: "Keep shooting",
          destructive: true,
          onConfirm: () => useApp.getState().endShoot(),
        });
      default:
        s.toast(`${cmd.title} isn't available here`, "info.circle");
    }
  } catch (e) {
    s.toast(errorMessage(e), "exclamationmark.triangle");
  }
}

export function openExport(surface: Surface, ids: string[]) {
  const s = useApp.getState();
  if (surface === "shoot" && s.shoot) {
    const shown = displayedItem(s.shoot);
    s.openModal({
      kind: "export",
      ctx: { sessionId: s.shoot.session.id, captureIds: null, selectionIds: [], selectedId: ids[0] ?? shown?.id ?? null, collection: null, look: s.shoot.look },
    });
    return;
  }
  if (surface === "session" && s.sessionDetail) {
    s.openModal({ kind: "export", ctx: { sessionId: s.sessionDetail.id, captureIds: null, selectionIds: [], selectedId: ids[0] ?? null, collection: null, look: null } });
    return;
  }
  const col = currentCollection();
  s.openModal({
    kind: "export",
    ctx: {
      sessionId: null,
      captureIds: s.library.items.map((i) => i.id),
      selectionIds: ids,
      selectedId: null,
      collection: col,
      look: null,
      title: col ? `Export · ${col.name}` : undefined,
    },
  });
}

/** The ids review commands act on for the current surface. */
export function currentTargets(): { surface: Surface; ids: string[] } {
  const s = useApp.getState();
  const top = s.modals.at(-1);
  if (top?.kind === "loupe" || top?.kind === "clientReview") {
    if (top.origin === "shoot") {
      const d = displayedItem(s.shoot);
      return { surface: "shoot", ids: d ? [d.id] : [] };
    }
    if (top.origin === "library") return { surface: "library", ids: s.library.loupeId ? [s.library.loupeId] : [] };
    return { surface: "session", ids: s.library.loupeId ? [s.library.loupeId] : [] };
  }
  if (s.showShoot && s.shoot) {
    const d = displayedItem(s.shoot);
    return { surface: "shoot", ids: d ? [d.id] : [] };
  }
  if (s.pane === "sessions" && s.sessionDetail) return { surface: "session", ids: s.library.loupeId ? [s.library.loupeId] : [] };
  return { surface: "library", ids: libraryTargets(s.library) };
}

export function canCapture(): boolean {
  const sh = useApp.getState().shoot;
  return !!sh?.identity && hasCap(sh.identity.capabilities, Cap.remoteCapture);
}
