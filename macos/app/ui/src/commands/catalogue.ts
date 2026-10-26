// Port of TetherCore `Commands` (ReviewEditor.swift): the one place every
// menu, context menu, keyboard shortcut and palette entry comes from.

import { COLOR_LABELS, hasCap, Cap, type Collection } from "../api";

export type CommandGroup = "review" | "organize" | "export" | "session" | "view" | "camera";

export interface Command {
  id: string;
  title: string;
  symbol: string;
  group: CommandGroup;
  /** Display hint, e.g. "1"…"5", "P", "⌘E", "Space". */
  shortcut?: string;
  isDestructive?: boolean;
}

export interface CommandContext {
  selectionCount: number;
  inLiveSession: boolean;
  cameraCapabilities: number;
  inCollection: Collection | null;
  canUndo: boolean;
  canRedo: boolean;
  /** The shoot screen: commands act on the displayed frame. */
  inShoot?: boolean;
}

const C = (id: string, title: string, symbol: string, group: CommandGroup, shortcut?: string, isDestructive = false): Command => ({
  id, title, symbol, group, shortcut, isDestructive,
});

export const Commands = {
  rate0: C("rate.0", "Clear rating", "star.slash", "review", "0"),
  rate: [1, 2, 3, 4, 5].map((n) => C(`rate.${n}`, `Rate ${n} star${n === 1 ? "" : "s"}`, "star.fill", "review", String(n))),
  pick: C("flag.pick", "Pick", "flag.fill", "review", "P"),
  reject: C("flag.reject", "Reject", "xmark", "review", "X"),
  unflag: C("flag.none", "Unflag", "flag.slash", "review", "U"),
  // The catalogue has no shortcuts for colour labels, so none are bound.
  labels: COLOR_LABELS.map((l) => C(`label.${l}`, `Label ${l}`, "circle.fill", "review")),
  clearLabel: C("label.none", "Clear label", "circle", "review"),
  tag: C("tag.add", "Add tags…", "number", "organize", "T"),
  addToCollection: C("collection.add", "Add to collection…", "rectangle.stack.badge.plus", "organize", "⇧⌘K"),
  newCollection: C("collection.new", "New collection from selection", "plus.rectangle.on.rectangle", "organize"),
  removeFromCollection: C("collection.remove", "Remove from this collection", "rectangle.stack.badge.minus", "organize", "⌫"),
  saveSmart: C("collection.smart", "Save filter as smart collection", "sparkles.rectangle.stack", "organize"),
  export: C("export", "Export…", "square.and.arrow.up", "export", "⌘E"),
  exportAgain: C("export.again", "Export like last time", "arrow.uturn.up", "export", "⇧⌘E"),
  colorMatch: C("look.match", "Match colour to this frame…", "wand.and.stars", "export"),
  compare: C("view.compare", "Compare", "rectangle.split.2x1", "view", "C"),
  clientReview: C("view.client", "Client review", "rectangle.inset.filled", "view", "⇧R"),
  selectAll: C("select.all", "Select all", "checkmark.circle", "view", "⌘A"),
  selectPicks: C("select.picks", "Select picks", "flag", "view"),
  invert: C("select.invert", "Invert selection", "arrow.triangle.2.circlepath", "view"),
  undo: C("undo", "Undo", "arrow.uturn.backward", "review", "⌘Z"),
  redo: C("redo", "Redo", "arrow.uturn.forward", "review", "⇧⌘Z"),
  capture: C("camera.capture", "Capture", "circle.inset.filled", "camera", "Space"),
  liveView: C("camera.liveview", "Live view", "eye", "camera", "L"),
  delete: C("delete", "Move to Trash", "trash", "organize", undefined, true),
  saveTemplate: C("session.template", "Save session as template", "doc.badge.plus", "session"),
  endSession: C("session.end", "End session", "stop.circle", "session"),
};

/** Commands that make sense right now, grouped and ordered for a menu. */
export function available(ctx: CommandContext): Command[] {
  const out: Command[] = [];
  const sel = ctx.selectionCount > 0;
  if (ctx.inLiveSession) {
    if (hasCap(ctx.cameraCapabilities, Cap.remoteCapture)) out.push(Commands.capture);
    if (hasCap(ctx.cameraCapabilities, Cap.liveView)) out.push(Commands.liveView);
  }
  if (sel) {
    out.push(...Commands.rate, Commands.rate0, Commands.pick, Commands.reject, Commands.unflag, ...Commands.labels, Commands.clearLabel,
      Commands.tag, Commands.addToCollection, Commands.newCollection);
    if (ctx.inCollection?.kind === "manual") out.push(Commands.removeFromCollection);
    out.push(Commands.export, Commands.exportAgain);
    if (ctx.selectionCount === 1) out.push(Commands.colorMatch);
    if (ctx.selectionCount === 2) out.push(Commands.compare);
    out.push(Commands.clientReview);
  }
  out.push(Commands.selectAll, Commands.selectPicks);
  if (sel) out.push(Commands.invert);
  if (ctx.inCollection?.kind === "smart" && !ctx.inCollection.isBuiltIn) out.push(Commands.saveSmart);
  if (ctx.canUndo) out.push(Commands.undo);
  if (ctx.canRedo) out.push(Commands.redo);
  if (ctx.inLiveSession) out.push(Commands.saveTemplate, Commands.endSession);
  if (sel) out.push(Commands.delete);
  return out;
}

/** Full-text match for the palette: title, group, shortcut. */
export function search(query: string, ctx: CommandContext, extra: Command[] = []): Command[] {
  const q = query.trim().toLowerCase();
  const all = [...available(ctx), ...extra];
  if (!q) return all;
  return all
    .filter((c) => c.title.toLowerCase().includes(q) || c.group.includes(q) || c.shortcut?.toLowerCase() === q)
    .sort((a, b) => Number(b.title.toLowerCase().startsWith(q)) - Number(a.title.toLowerCase().startsWith(q)));
}

export const GROUP_TITLES: Record<CommandGroup, string> = {
  review: "Review", organize: "Organize", export: "Export", session: "Session", view: "View", camera: "Camera",
};

export interface CommandSection {
  group: CommandGroup;
  title: string;
  commands: Command[];
}

/** Groups keeping first-appearance order so the most relevant group stays on top. */
export function sections(commands: Command[]): CommandSection[] {
  const order: CommandGroup[] = [];
  const buckets = new Map<CommandGroup, Command[]>();
  for (const c of commands) {
    if (!buckets.has(c.group)) {
      order.push(c.group);
      buckets.set(c.group, []);
    }
    buckets.get(c.group)!.push(c);
  }
  return order.map((g) => ({ group: g, title: GROUP_TITLES[g], commands: buckets.get(g)! }));
}

export interface ParsedShortcut {
  key: string;
  command: boolean;
  shift: boolean;
  option: boolean;
}

/** "⇧⌘E" → { key: "e", command, shift }. "Space" → " ", "⌫" → "Backspace". */
export function parseShortcut(hint: string): ParsedShortcut | null {
  let rest = hint.trim();
  if (!rest) return null;
  const out: ParsedShortcut = { key: "", command: false, shift: false, option: false };
  while (rest && "⌘⇧⌥".includes(rest[0])) {
    if (rest[0] === "⌘") out.command = true;
    else if (rest[0] === "⇧") out.shift = true;
    else out.option = true;
    rest = rest.slice(1);
  }
  const lower = rest.toLowerCase();
  if (lower === "space") out.key = " ";
  else if (lower === "⌫" || lower === "delete") out.key = "Backspace";
  else if (rest.length === 1) out.key = lower;
  else return null;
  return out;
}

export function matchesShortcut(e: KeyboardEvent, p: ParsedShortcut): boolean {
  const key = e.key === "Delete" ? "Backspace" : e.key.length === 1 ? e.key.toLowerCase() : e.key;
  return key === p.key && e.metaKey === p.command && e.shiftKey === p.shift && e.altKey === p.option && !e.ctrlKey;
}
