import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { cameraDisplayName, isFailed, isReady, downloadProgress, SORT_NAMES, type CaptureItem, type CaptureSort } from "../../api";
import { useApp, visibleTiles, type CaptureStack } from "../../state/store";
import { Icon } from "../../components/Icon";
import { MenuButton, openContextMenu, commandItems, type MenuItem } from "../../components/Menu";
import { CaptureImage } from "../../components/media";
import { TileBadges } from "../../components/review";
import { EmptyState, ProgressRing, Spinner } from "../../components/common";
import { FilterChips } from "./FilterChips";
import { commandsFor, currentCollection, runCommand, newCollectionDraft, openExport } from "../../commands/dispatcher";
import { gridMetrics } from "../keyboard";
import { importFiles, pickCatalog } from "./actions";
import { isEmptyFilter, withSearch } from "../../lib/filter";
import { plural } from "../../lib/format";

const GAP = 3;
const PAD = 10;

export function LibraryContent() {
  const l = useApp((s) => s.library);
  const sources = useApp((s) => s.sources);
  const undo = useApp((s) => s.undo);
  const st = useApp.getState;

  const title = useMemo(() => {
    if (!sources) return "Library";
    const src = l.source;
    if (src.kind === "collection") return [...sources.builtIns, ...sources.manual, ...sources.smart].find((c) => c.id === src.id)?.name ?? "Collection";
    if (src.kind === "session") return sources.sessions.find((s) => s.id === src.id)?.name ?? "Session";
    const cam = sources.cameras.find((c) => c.id === src.id);
    return cam ? cameraDisplayName(cam) : "Camera";
  }, [sources, l.source]);

  const sortItems: MenuItem[] = (Object.keys(SORT_NAMES) as CaptureSort[]).map((s) => ({ title: SORT_NAMES[s], checked: l.sort === s, onSelect: () => st().setSort(s) }));

  return (
    <div className="library">
      <div className="toolbar">
        <div className="col" style={{ gap: 0, minWidth: 150, flex: "0 1 auto" }}>
          <span className="title truncate">{title}</span>
          <span className="t-hud ink-2 truncate">{plural(l.total, "photo")}{l.selection.ids.length ? ` · ${l.selection.ids.length} selected` : ""}</span>
        </div>
        <span className="spacer" />
        <div className="search-field">
          <Icon name="magnifyingglass" size={13} className="ink-2" />
          <input
            value={l.search}
            placeholder="Filename, session, tag"
            aria-label="Search the library"
            spellCheck={false}
            onChange={(e) => st().setSearch(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Escape" && l.search) {
                e.stopPropagation();
                st().setSearch("");
              }
            }}
          />
          {l.search ? (
            <button className="icon-btn" style={{ width: 18, height: 18 }} aria-label="Clear search" onClick={() => st().setSearch("")}>
              <Icon name="xmark.circle.fill" size={13} />
            </button>
          ) : null}
        </div>
        <MenuButton
          label="Import"
          title="Import"
          items={[
            { title: "Import photos or a folder…", icon: "square.and.arrow.down", onSelect: () => importFiles(l.source.kind === "session" ? l.source.id : null) },
            { title: "Sync ratings from a catalog…", icon: "arrow.triangle.2.circlepath", onSelect: pickCatalog },
          ]}
        >
          <Icon name="square.and.arrow.down" size={16} />
        </MenuButton>
        <button className="icon-btn" title={undo.undoTitle ? `Undo ${undo.undoTitle} (⌘Z)` : "Nothing to undo"} aria-label="Undo" disabled={!undo.undoTitle} onClick={() => st().doUndo()}>
          <Icon name="arrow.uturn.backward" size={16} />
        </button>
        <button className="icon-btn" title={undo.redoTitle ? `Redo ${undo.redoTitle} (⇧⌘Z)` : "Nothing to redo"} aria-label="Redo" disabled={!undo.redoTitle} onClick={() => st().doRedo()}>
          <Icon name="arrow.uturn.forward" size={16} />
        </button>
        <MenuButton label={`Sort, currently ${SORT_NAMES[l.sort]}`} title={`Sort: ${SORT_NAMES[l.sort]}`} items={sortItems} align="right">
          <Icon name="arrow.up.arrow.down" size={16} />
        </MenuButton>
        <MenuButton
          label="View options"
          title="View"
          align="right"
          items={() => [
            { kind: "header", title: "Tiles per row" },
            ...[3, 4, 5, 6, 8, 10].map((n): MenuItem => ({ title: `${n} per row`, checked: l.columns === n, onSelect: () => st().setColumns(n) })),
            { kind: "divider" },
            { title: "Stack RAW + JPEG", icon: "square.2.layers.3d", checked: l.stackPairs, onSelect: () => st().setStackPairs(!l.stackPairs) },
            { title: "Command palette", icon: "command", shortcut: "⌘K", onSelect: () => st().openModal({ kind: "palette" }) },
          ]}
        >
          <Icon name="square.grid.3x3" size={16} />
        </MenuButton>
        <input
          type="range"
          className="slider zoom-slider"
          aria-label="Zoom"
          title="Zoom (⌘+ / ⌘−)"
          min={2}
          max={10}
          step={1}
          value={12 - l.columns}
          style={{ ["--pct" as string]: `${((12 - l.columns - 2) / 8) * 100}%` }}
          onChange={(e) => st().setColumns(12 - Number(e.target.value))}
        />
        <button className={`icon-btn${l.inspectorOpen ? " on" : ""}`} title="Inspector (⌘I)" aria-label="Inspector" onClick={() => st().setInspector(!l.inspectorOpen)}>
          <Icon name="sidebar.right" size={16} />
        </button>
      </div>
      <div className="filter-bar">
        <FilterChips
          filter={l.filter}
          onChange={(f) => st().setFilter(f)}
          sessions={sources?.sessions ?? []}
          cameras={sources?.cameras ?? []}
          onSaveSmart={() => st().openModal({ kind: "collectionEditor", draft: newCollectionDraft("smart", withSearch(l.filter, l.search)) })}
        />
      </div>
      <Grid />
      <BatchBar />
    </div>
  );
}

function Grid() {
  const l = useApp((s) => s.library);
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(800);
  const [scroll, setScroll] = useState({ top: 0, height: 600 });
  const tiles = useMemo(() => visibleTiles(l), [l]);
  const ordered = useMemo(() => tiles.map((t) => t.item.id), [tiles]);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => {
      setWidth(el.clientWidth);
      setScroll({ top: el.scrollTop, height: el.clientHeight });
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const cols = Math.max(1, l.columns);
  gridMetrics.columns = cols;
  const side = Math.max(40, (width - PAD * 2 - GAP * (cols - 1)) / cols);
  const pitch = side + GAP;
  const rows = Math.ceil(tiles.length / cols);
  const firstRow = Math.max(0, Math.floor((scroll.top - PAD) / pitch) - 2);
  const lastRow = Math.min(rows, Math.ceil((scroll.top + scroll.height) / pitch) + 2);

  useEffect(() => {
    const el = ref.current;
    const id = l.scrollToId;
    if (!el || !id) return;
    const i = ordered.indexOf(id);
    if (i < 0) return;
    const top = PAD + Math.floor(i / cols) * pitch;
    if (top < el.scrollTop) el.scrollTop = top - 8;
    else if (top + side > el.scrollTop + el.clientHeight) el.scrollTop = top + side - el.clientHeight + 8;
    useApp.setState((s) => ({ library: { ...s.library, scrollToId: null } }));
  }, [l.scrollToId, ordered, cols, pitch, side]);

  if (!l.items.length) {
    return (
      <div className="grid-scroll" ref={ref}>
        {l.loading ? (
          <div className="col" style={{ alignItems: "center", paddingTop: 80 }}><Spinner /></div>
        ) : isEmptyFilter(l.filter) && !l.search ? (
          <EmptyState icon="photo.on.rectangle" title="No photos here yet" message="Frames from your sessions appear here as they download." />
        ) : (
          <EmptyState icon="line.3.horizontal.decrease.circle" title="Nothing matches" message="Clear a chip or two to widen the view." action="Clear filters"
            onAction={() => { useApp.getState().setSearch(""); useApp.getState().setFilter({}); }} />
        )}
      </div>
    );
  }

  const visible = tiles.slice(firstRow * cols, lastRow * cols);
  return (
    <div
      className="grid-scroll"
      ref={ref}
      tabIndex={-1}
      onScroll={(e) => {
        const el = e.currentTarget;
        setScroll({ top: el.scrollTop, height: el.clientHeight });
        if (el.scrollTop + el.clientHeight > el.scrollHeight - 600) useApp.getState().loadMore();
      }}
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) useApp.getState().clearSelection();
      }}
    >
      <div style={{ position: "relative", height: PAD * 2 + rows * pitch - GAP }} onMouseDown={(e) => { if (e.target === e.currentTarget) useApp.getState().clearSelection(); }}>
        {visible.map((t, k) => {
          const i = firstRow * cols + k;
          return (
            <Tile
              key={t.item.id}
              item={t.item}
              stack={t.stack}
              side={side}
              left={PAD + (i % cols) * pitch}
              top={PAD + Math.floor(i / cols) * pitch}
              ordered={ordered}
              selected={l.selection.ids.includes(t.item.id)}
              focused={l.focusedId === t.item.id}
              collapsed={t.stack.items.length > 1 && l.stackPairs && !l.expanded.includes(t.stack.key)}
            />
          );
        })}
      </div>
    </div>
  );
}

function Tile({
  item, stack, side, left, top, ordered, selected, focused, collapsed,
}: { item: CaptureItem; stack: CaptureStack; side: number; left: number; top: number; ordered: string[]; selected: boolean; focused: boolean; collapsed: boolean }) {
  const st = useApp.getState;
  const ready = isReady(item);
  const radius = side > 140 ? 9 : 4;

  function menu(e: React.MouseEvent) {
    const s = st();
    let ids = s.library.selection.ids;
    if (!ids.includes(item.id)) {
      s.selectTile(item.id, "replace", ordered);
      ids = [item.id];
    }
    const col = currentCollection();
    const head: MenuItem[] = [
      { title: "Open in loupe", icon: "eye", shortcut: "Space", onSelect: () => s.setLoupe(item.id) },
      { title: "Inspector", icon: "info.circle", onSelect: () => { s.setFocused(item.id); s.setInspector(true); } },
    ];
    if (stack.items.length > 1 && s.library.stackPairs) {
      head.push({ title: collapsed ? "Expand stack" : "Collapse stack", icon: "square.2.layers.3d", onSelect: () => s.toggleStack(stack.key) });
    }
    head.push({ title: "Reveal in session", icon: "rectangle.stack.badge.person.crop", onSelect: () => s.revealInSession(item) });
    openContextMenu(e, [
      ...head,
      { kind: "divider" },
      ...commandItems(commandsFor("library", ids, col), (c) => runCommand(c, ids, "library"), ["select."]),
    ]);
  }

  return (
    <div
      className={`tile${selected ? " selected" : ""}${focused ? " focused" : ""}`}
      style={{ left, top, width: side, height: side, borderRadius: radius }}
      role="button"
      aria-label={`${item.filename}${item.rating ? `, ${item.rating} stars` : ""}${item.flag !== "none" ? `, ${item.flag}` : ""}`}
      aria-pressed={selected}
      onMouseDown={(e) => {
        if (e.button !== 0) return;
        const mode = e.metaKey ? "toggle" : e.shiftKey ? "extend" : "replace";
        if (mode === "replace" && selected && st().library.selection.ids.length > 1) {
          st().setFocused(item.id);
          return;
        }
        st().selectTile(item.id, mode, ordered);
      }}
      onClick={(e) => {
        if (!e.metaKey && !e.shiftKey && st().library.selection.ids.length > 1 && selected) st().selectTile(item.id, "replace", ordered);
      }}
      onDoubleClick={() => ready && st().setLoupe(item.id)}
      onContextMenu={menu}
    >
      {ready || item.state.kind === "downloading" ? (
        <CaptureImage item={item} variant="thumb" style={{ opacity: item.flag === "reject" ? 0.4 : undefined, borderRadius: radius }} />
      ) : null}
      {!ready ? <div className="tile-dim" /> : null}
      {isFailed(item) ? (
        <Icon name="exclamationmark.triangle.fill" size={20} className="c-danger tile-center" />
      ) : !ready ? (
        <span className="tile-center"><ProgressRing progress={downloadProgress(item)} /></span>
      ) : null}
      <TileBadges item={item} pairCount={collapsed ? stack.items.length : 0} compact={side < 110} />
      {collapsed ? (
        <button className="stack-toggle" title="Expand RAW + JPEG" aria-label="Expand stack" onMouseDown={(e) => e.stopPropagation()} onClick={(e) => { e.stopPropagation(); st().toggleStack(stack.key); }} />
      ) : null}
      {selected ? <Icon name="checkmark.circle.fill" size={18} className="tile-check" /> : null}
    </div>
  );
}

const QUICK = ["rate.1", "rate.2", "rate.3", "rate.4", "rate.5", "flag.pick", "flag.reject", "tag.add", "collection.add", "export"];

/** Appears with a multi-selection: count, quick review commands, everything else in More. */
function BatchBar() {
  const sel = useApp((s) => s.library.selection.ids);
  const undo = useApp((s) => s.undo);
  if (sel.length < 2) return null;
  const col = currentCollection();
  const cmds = commandsFor("library", sel, col);
  void undo;
  const quick = cmds.filter((c) => QUICK.includes(c.id));
  return (
    <div className="batch-bar glass">
      <span className="t-hud ink-0" style={{ minWidth: 80 }}>{sel.length} selected</span>
      <div className="row" style={{ gap: 2 }}>
        {quick.map((c) => (
          <button
            key={c.id}
            className="batch-btn"
            title={`${c.title}${c.shortcut ? ` (${c.shortcut})` : ""}`}
            aria-label={c.title}
            style={c.id === "flag.reject" ? { color: "var(--danger)" } : c.id === "flag.pick" ? { color: "var(--ok)" } : undefined}
            onClick={() => (c.id === "export" ? openExport("library", sel) : runCommand(c, sel, "library"))}
          >
            {c.id.startsWith("rate.") ? <span className="t-exposure" style={{ fontSize: 15 }}>{c.id.slice(5)}<span style={{ color: "var(--pick)", fontSize: 11 }}>★</span></span> : <Icon name={c.symbol} size={16} />}
          </button>
        ))}
        <MenuButton
          className="batch-btn"
          label="More actions"
          title="More"
          items={() => commandItems(cmds.filter((c) => !QUICK.includes(c.id)), (c) => runCommand(c, sel, "library"))}
        >
          <Icon name="ellipsis.circle" size={16} />
        </MenuButton>
      </div>
      <span className="spacer" />
      <button className="btn plain small" onClick={() => useApp.getState().clearSelection()}>Clear</button>
    </div>
  );
}
