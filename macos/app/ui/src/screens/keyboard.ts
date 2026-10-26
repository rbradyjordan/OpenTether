import { useEffect } from "react";
import { useApp, displayedItem, visibleTiles } from "../state/store";
import { useMenu } from "../components/Menu";
import { commandsFor, currentCollection, currentTargets, runCommand, canCapture, openExport, type Surface } from "../commands/dispatcher";
import { matchesShortcut, parseShortcut, type Command } from "../commands/catalogue";
import { isReady } from "../api";

/** Column count the library grid is laid out with right now (for ↑/↓). */
export const gridMetrics = { columns: 4 };

/** Full-window overlays where review keys act on the frame on screen. */
const REVIEW_OVERLAYS = new Set(["loupe", "clientReview"]);

/** Shoot keys: commands that act in place (sheets stay on menus), plus export and client review. */
const SHOOT_PREFIXES = ["rate.", "flag.", "label.", "camera.", "undo", "redo", "export", "view.client", "tag.add", "collection.add"];

function isEditable(t: EventTarget | null): boolean {
  if (!(t instanceof HTMLElement)) return false;
  return t.isContentEditable || t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT";
}

function step(delta: number) {
  const s = useApp.getState();
  const top = s.modals.at(-1);
  const origin = top && (top.kind === "loupe" || top.kind === "clientReview") ? top.origin : s.showShoot ? "shoot" : null;
  if (origin === "shoot" && s.shoot) {
    const ready = s.shoot.items.filter((i) => isReady(i));
    const cur = displayedItem(s.shoot);
    const i = cur ? ready.findIndex((x) => x.id === cur.id) : -1;
    const next = ready[i + delta];
    if (next) s.shootSelect(next.id);
    return true;
  }
  if (origin === "library" || origin === "session") {
    const list = origin === "library" ? visibleTiles(s.library).map((t) => t.item).filter(isReady) : (s.sessionDetail?.items ?? []).filter(isReady);
    const i = list.findIndex((x) => x.id === s.library.loupeId);
    const next = list[i + delta];
    if (next) {
      useApp.setState((st) => ({
        library: origin === "library"
          ? { ...st.library, loupeId: next.id, focusedId: next.id, scrollToId: next.id, selection: { ids: [next.id], anchor: next.id } }
          : { ...st.library, loupeId: next.id },
      }));
    }
    return true;
  }
  return false;
}

function gridMove(e: KeyboardEvent): boolean {
  const s = useApp.getState();
  const tiles = visibleTiles(s.library).map((t) => t.item.id);
  if (!tiles.length) return false;
  const cols = Math.max(1, gridMetrics.columns);
  const cur = s.library.focusedId ? tiles.indexOf(s.library.focusedId) : -1;
  let next = cur;
  switch (e.key) {
    case "ArrowLeft": next = cur < 0 ? 0 : Math.max(0, cur - 1); break;
    case "ArrowRight": next = cur < 0 ? 0 : Math.min(tiles.length - 1, cur + 1); break;
    case "ArrowUp": next = cur < 0 ? 0 : cur - cols >= 0 ? cur - cols : cur; break;
    case "ArrowDown": next = cur < 0 ? 0 : cur + cols < tiles.length ? cur + cols : cur; break;
    case "Home": next = 0; break;
    case "End": next = tiles.length - 1; break;
    default: return false;
  }
  const id = tiles[next];
  s.selectTile(id, e.shiftKey ? "extend" : "replace", tiles);
  useApp.setState((st) => ({ library: { ...st.library, scrollToId: id } }));
  return true;
}

function tryCommands(e: KeyboardEvent, commands: Command[], surface: Surface, ids: string[]): boolean {
  for (const cmd of commands) {
    if (!cmd.shortcut) continue;
    const p = parseShortcut(cmd.shortcut);
    if (p && matchesShortcut(e, p)) {
      e.preventDefault();
      runCommand(cmd, ids, surface);
      return true;
    }
  }
  return false;
}

function onKey(e: KeyboardEvent) {
  const s = useApp.getState();
  if (e.defaultPrevented) return;

  // Menus own the keyboard while open (arrow keys handled by the menu itself).
  if (useMenu.getState().open) {
    if (e.key === "Escape") {
      e.preventDefault();
      useMenu.getState().close();
    }
    return;
  }

  if (e.key === "k" && e.metaKey && !e.shiftKey) {
    e.preventDefault();
    if (s.modals.at(-1)?.kind === "palette") s.closeModal("palette");
    else s.openModal({ kind: "palette" });
    return;
  }
  if ((e.key === "," || e.code === "Comma") && e.metaKey) {
    e.preventDefault();
    s.openModal({ kind: "settings" });
    return;
  }

  const editable = isEditable(e.target);
  if (e.key === "Escape") {
    if (editable && e.target instanceof HTMLElement && !s.modals.length) {
      e.target.blur();
      return;
    }
    e.preventDefault();
    if (s.modals.length) {
      s.closeModal(s.modals.at(-1)!.kind);
      return;
    }
    if (s.showShoot) return;
    if (s.pane === "library" && s.library.selection.ids.length) s.clearSelection();
    return;
  }
  if (editable || !s.settings?.hasOnboarded) return;

  const top = s.modals.at(-1);
  // Sheets take the keyboard; only the full-window review overlays pass keys through.
  if (top && !REVIEW_OVERLAYS.has(top.kind)) return;

  const { surface, ids } = currentTargets();

  // ⌘E opens the export sheet everywhere, even with nothing selected.
  if (e.key === "e" && e.metaKey && !e.shiftKey && !e.altKey && (s.showShoot || s.pane === "library" || top)) {
    e.preventDefault();
    openExport(surface, ids);
    return;
  }

  if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
    if (!e.metaKey && (top || s.showShoot)) {
      if (step(e.key === "ArrowLeft" ? -1 : 1)) e.preventDefault();
      return;
    }
  }

  if (s.showShoot && !top) {
    if (e.key === " " && !e.metaKey) {
      e.preventDefault();
      if (canCapture()) s.capture(true);
      else s.toast("This connection has no remote shutter: press the camera's own button.", "info.circle");
      return;
    }
    if (e.key === "Enter" && displayedItem(s.shoot)) {
      e.preventDefault();
      s.openModal({ kind: "loupe", origin: "shoot" });
      return;
    }
    const cmds = commandsFor("shoot", ids).filter((c) => SHOOT_PREFIXES.some((p) => c.id.startsWith(p)));
    tryCommands(e, cmds, "shoot", ids);
    return;
  }

  if (top && REVIEW_OVERLAYS.has(top.kind)) {
    if (e.key === " ") {
      e.preventDefault();
      s.closeModal(top.kind);
      return;
    }
    const cmds = commandsFor(surface, ids).filter((c) => /^(rate|flag|label|undo|redo|tag|export|collection\.add)/.test(c.id));
    tryCommands(e, cmds, surface, ids);
    return;
  }

  if (s.pane === "library") {
    if (["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"].includes(e.key) && !e.metaKey) {
      if (gridMove(e)) e.preventDefault();
      return;
    }
    if ((e.key === " " || e.key === "Enter") && s.library.focusedId) {
      e.preventDefault();
      s.setLoupe(s.library.focusedId);
      return;
    }
    if (e.key === "i" && e.metaKey) {
      e.preventDefault();
      s.setInspector(!s.library.inspectorOpen);
      return;
    }
    if ((e.key === "=" || e.key === "+") && e.metaKey) {
      e.preventDefault();
      s.setColumns(s.library.columns - 1);
      return;
    }
    if (e.key === "-" && e.metaKey) {
      e.preventDefault();
      s.setColumns(s.library.columns + 1);
      return;
    }
    tryCommands(e, commandsFor("library", ids, currentCollection()), "library", ids);
    return;
  }

  // Connect / Sessions panes: only undo and redo apply.
  tryCommands(e, commandsFor(surface, []).filter((c) => c.id === "undo" || c.id === "redo"), surface, []);
}

export function useKeyRouter() {
  useEffect(() => {
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
}
