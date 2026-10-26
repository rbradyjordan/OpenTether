import { useEffect, useMemo, useRef, useState } from "react";
import { api } from "../../api";
import { useApp } from "../../state/store";
import { search, sections, type Command } from "../../commands/catalogue";
import { commandContext, currentCollection, currentTargets, runCommand } from "../../commands/dispatcher";
import { Icon } from "../../components/Icon";
import { Kbd } from "../../components/common";
import { importFiles, pickCatalog } from "../library/actions";

/** App-level entries that aren't review commands (navigation, sessions, imports). */
function extras(): Command[] {
  const s = useApp.getState();
  const out: Command[] = [
    { id: "nav.connect", title: "Connect a camera", symbol: "cable.connector", group: "session" },
    { id: "nav.sessions", title: "Show sessions", symbol: "rectangle.stack", group: "session" },
    { id: "nav.newSession", title: "New session…", symbol: "plus", group: "session" },
    { id: "nav.exports", title: "Export progress", symbol: "arrow.up.doc", group: "export" },
    { id: "nav.import", title: "Import photos or a folder…", symbol: "square.and.arrow.down", group: "organize" },
    { id: "nav.catalog", title: "Sync ratings from a catalog…", symbol: "arrow.triangle.2.circlepath", group: "organize" },
    { id: "nav.inspector", title: s.library.inspectorOpen ? "Hide inspector" : "Show inspector", symbol: "sidebar.right", group: "view", shortcut: "⌘I" },
    { id: "nav.settings", title: "Settings", symbol: "gearshape", group: "view", shortcut: "⌘," },
  ];
  if (s.shoot) out.unshift({ id: "nav.shoot", title: s.showShoot ? "Back to library, keep shooting" : "Show the live shoot", symbol: "camera.aperture", group: "camera" });
  else out.push({ id: "nav.demo", title: "Start a demo session", symbol: "play.rectangle", group: "session" });
  if (s.shoot) out.push({ id: "nav.looks", title: "Looks…", symbol: "camera.filters", group: "camera" });
  return out;
}

function runExtra(id: string) {
  const s = useApp.getState();
  switch (id) {
    case "nav.connect": s.setShowShoot(false); s.setPane("connect"); s.popTo("connect", 0); break;
    case "nav.sessions": s.setShowShoot(false); s.setPane("sessions"); s.popTo("sessions", 0); break;
    case "nav.newSession": s.openModal({ kind: "newSession" }); break;
    case "nav.exports": s.openModal({ kind: "exportProgress", sessionId: null }); break;
    case "nav.import": importFiles(null); break;
    case "nav.catalog": pickCatalog(); break;
    case "nav.inspector": s.setPane("library"); s.setInspector(!s.library.inspectorOpen); break;
    case "nav.settings": s.openModal({ kind: "settings" }); break;
    case "nav.shoot": s.setShowShoot(!s.showShoot); break;
    case "nav.demo": api.demoStart().then((st) => s.activate(st)).catch(s.fail); break;
    case "nav.looks": s.openModal({ kind: "looks" }); break;
  }
}

/** ⌘K: search every available command, grouped, with its shortcut. Return runs the highlighted one. */
export function CommandPalette({ onClose }: { onClose: () => void }) {
  const [query, setQuery] = useState("");
  const [highlight, setHighlight] = useState(0);
  const listRef = useRef<HTMLDivElement>(null);
  const target = useMemo(() => currentTargets(), []);
  const results = useMemo(() => {
    const ctx = commandContext(target.surface, target.ids, target.surface === "library" ? currentCollection() : null);
    return search(query, ctx, extras());
  }, [query, target]);
  const grouped = sections(results);
  const flat = grouped.flatMap((g) => g.commands);

  useEffect(() => setHighlight(0), [query]);
  useEffect(() => {
    listRef.current?.querySelector(`[data-index="${highlight}"]`)?.scrollIntoView({ block: "nearest" });
  }, [highlight]);

  function run(cmd: Command) {
    onClose();
    if (cmd.id.startsWith("nav.")) runExtra(cmd.id);
    else runCommand(cmd, target.ids, target.surface);
  }

  let index = -1;
  return (
    <div className="palette glass" role="dialog" aria-label="Command palette" onMouseDown={(e) => e.stopPropagation()}>
      <div className="palette-search">
        <Icon name="magnifyingglass" size={16} className="ink-2" />
        <input
          autoFocus
          value={query}
          placeholder={target.ids.length ? `Type a command for ${target.ids.length === 1 ? "1 photo" : `${target.ids.length} photos`}…` : "Type a command…"}
          aria-label="Search commands"
          spellCheck={false}
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "ArrowDown") {
              e.preventDefault();
              setHighlight((h) => Math.min(flat.length - 1, h + 1));
            } else if (e.key === "ArrowUp") {
              e.preventDefault();
              setHighlight((h) => Math.max(0, h - 1));
            } else if (e.key === "Enter") {
              e.preventDefault();
              const c = flat[highlight] ?? flat[0];
              if (c) run(c);
            }
          }}
        />
        <Kbd>esc</Kbd>
      </div>
      <div className="palette-list" ref={listRef}>
        {flat.length === 0 ? <div className="t-callout" style={{ padding: 16 }}>No command matches “{query}”</div> : null}
        {grouped.map((g) => (
          <div key={g.group}>
            <div className="palette-group">{g.title}</div>
            {g.commands.map((c) => {
              index += 1;
              const i = index;
              const label = c.id.startsWith("label.") && c.id !== "label.none" ? c.id.slice(6) : null;
              return (
                <button
                  key={c.id}
                  data-index={i}
                  className={`palette-row${i === highlight ? " active" : ""}${c.isDestructive ? " destructive" : ""}`}
                  onMouseMove={() => setHighlight(i)}
                  onClick={() => run(c)}
                >
                  <Icon name={c.symbol} size={15} style={{ color: label ? `var(--label-${label})` : c.isDestructive ? "var(--danger)" : "var(--accent)" }} />
                  <span className="fill truncate">{c.title}</span>
                  {c.shortcut ? <Kbd>{c.shortcut}</Kbd> : null}
                </button>
              );
            })}
          </div>
        ))}
      </div>
    </div>
  );
}
