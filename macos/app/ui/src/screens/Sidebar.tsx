import { api, cameraDisplayName, isLiveStatus, sourceKey, type Collection, type ColorLabel, type LibrarySource } from "../api";
import { useApp } from "../state/store";
import { Icon } from "../components/Icon";
import { openContextMenu, type MenuItem } from "../components/Menu";
import { labelColor } from "../components/review";
import { newCollectionDraft, openExport } from "../commands/dispatcher";
import { withSearch } from "../lib/filter";
import brandIcon from "../assets/brand-icon.png";

function SourceRow({
  name, symbol, tint, count, selected, onClick, onContext, accent,
}: { name: string; symbol: string; tint?: ColorLabel; count?: number; selected: boolean; onClick: () => void; onContext?: (e: React.MouseEvent) => void; accent?: boolean }) {
  return (
    <button className={`side-row${selected ? " selected" : ""}`} onClick={onClick} onContextMenu={onContext} aria-current={selected ? "page" : undefined}>
      <Icon name={symbol} size={15} style={{ color: tint && tint !== "none" ? labelColor(tint) : accent ? "var(--accent)" : undefined }} />
      <span className="truncate fill" style={accent ? { color: "var(--accent)" } : undefined}>{name || "Untitled"}</span>
      {count != null ? <span className="side-count">{count}</span> : null}
    </button>
  );
}

function Section({ title, children, trailing }: { title: string; children: React.ReactNode; trailing?: React.ReactNode }) {
  return (
    <div className="side-section">
      <div className="side-heading">
        <span>{title}</span>
        <span className="spacer" />
        {trailing}
      </div>
      {children}
    </div>
  );
}

export function Sidebar() {
  const sources = useApp((s) => s.sources);
  const pane = useApp((s) => s.pane);
  const source = useApp((s) => s.library.source);
  const shoot = useApp((s) => s.shoot);
  const sessionCount = useApp((s) => s.sessions.length);
  const st = useApp.getState;

  const isSel = (src: LibrarySource) => pane === "library" && sourceKey(src) === sourceKey(source);
  const count = (src: LibrarySource) => sources?.counts[sourceKey(src)] ?? 0;

  function collectionMenu(c: Collection, index: number, list: Collection[]): MenuItem[] {
    const items: MenuItem[] = [
      { title: c.isPinned ? "Unpin" : "Pin", icon: c.isPinned ? "pin.slash" : "pin", onSelect: () => api.collectionTogglePin({ id: c.id }) },
    ];
    if (!c.isBuiltIn) {
      items.push(
        { title: "Rename…", icon: "pencil", onSelect: () => st().openModal({
          kind: "rename", title: "Rename collection", value: c.name,
          onSave: (name) => api.collectionSave({ collection: { ...c, name } }).catch(st().fail),
        }) },
        { title: c.kind === "smart" ? "Edit rule…" : "Edit…", icon: "slider.horizontal.3", onSelect: () => st().openModal({ kind: "collectionEditor", draft: c }) },
      );
      if (c.kind === "manual") {
        items.push(
          { kind: "divider" },
          { title: "Move up", icon: "chevron.up", disabled: index === 0, onSelect: () => api.collectionMove({ id: c.id, toIndex: index - 1 }) },
          { title: "Move down", icon: "chevron.down", disabled: index === list.length - 1, onSelect: () => api.collectionMove({ id: c.id, toIndex: index + 1 }) },
        );
      }
      items.push(
        { kind: "divider" },
        { title: "Export collection…", icon: "square.and.arrow.up", onSelect: () => st().selectSource({ kind: "collection", id: c.id }).then(() => openExport("library", [])) },
        { title: "Delete", icon: "trash", destructive: true, onSelect: () => st().openModal({
          kind: "confirm", title: "Delete this collection?", message: "Photos stay in the library; only the collection goes.",
          confirmTitle: "Delete collection", destructive: true, cancelTitle: "Keep",
          onConfirm: () => api.collectionDelete({ id: c.id }).then(() => {
            if (sourceKey(st().library.source) === sourceKey({ kind: "collection", id: c.id })) st().selectSource({ kind: "collection", id: "builtin.all" });
          }),
        }) },
      );
    }
    return items;
  }

  const collectionRows = (list: Collection[]) =>
    list.map((c, i) => {
      const src: LibrarySource = { kind: "collection", id: c.id };
      return (
        <SourceRow key={c.id} name={c.name} symbol={c.symbol} tint={c.tint} count={count(src)} selected={isSel(src)}
          onClick={() => st().selectSource(src)} onContext={(e) => openContextMenu(e, collectionMenu(c, i, list))} />
      );
    });

  const liveName = shoot ? (shoot.identity ? cameraDisplayName(shoot.identity) : shoot.isDemo ? "Demo camera" : "FTP receiver") : "";

  return (
    <nav className="sidebar" aria-label="Sources">
      <div className="sidebar-header">
        <img className="brand-mark" src={brandIcon} alt="" draggable={false} />
        <span className="t-headline truncate">Open Tether</span>
        <span className="spacer" />
        <button className="icon-btn" title="Command palette (⌘K)" aria-label="Command palette" onClick={() => st().openModal({ kind: "palette" })}>
          <Icon name="command" size={15} />
        </button>
        <button className="icon-btn" title="Settings (⌘,)" aria-label="Settings" onClick={() => st().openModal({ kind: "settings" })}>
          <Icon name="gearshape" size={16} />
        </button>
      </div>
      <div className="sidebar-scroll">
        <Section title="Shoot">
          {shoot ? (
            <SourceRow name={`${isLiveStatus(shoot.status) ? "Live" : "Session"} · ${liveName}`} symbol="camera.aperture" accent selected={false}
              onClick={() => st().setShowShoot(true)} />
          ) : null}
          <SourceRow name="Connect a camera" symbol="cable.connector" selected={pane === "connect"} onClick={() => st().setPane("connect")} />
          <SourceRow name="Sessions" symbol="rectangle.stack" selected={pane === "sessions"} onClick={() => st().setPane("sessions")}
            count={sessionCount || undefined} />
        </Section>
        {sources ? (
          <>
            <Section title="Library">{collectionRows(sources.builtIns)}</Section>
            {sources.pinned.length ? <Section title="Pinned">{collectionRows(sources.pinned)}</Section> : null}
            <Section
              title="My collections"
              trailing={
                <button className="icon-btn" style={{ width: 22, height: 22 }} title="New collection" aria-label="New collection"
                  onClick={() => st().openModal({ kind: "collectionEditor", draft: newCollectionDraft("manual") })}>
                  <Icon name="plus" size={13} strokeWidth={2.2} />
                </button>
              }
            >
              {collectionRows(sources.manual)}
              <button className="side-row quiet" onClick={() => st().openModal({ kind: "collectionEditor", draft: newCollectionDraft("smart", withSearch(st().library.filter, st().library.search)) })}>
                <Icon name="sparkles" size={15} />
                <span className="truncate">New smart collection from filter</span>
              </button>
            </Section>
            {sources.smart.length ? <Section title="Smart collections">{collectionRows(sources.smart)}</Section> : null}
            <Section title="Sessions">
              {sources.sessions.slice(0, 30).map((s) => {
                const src: LibrarySource = { kind: "session", id: s.id };
                return (
                  <SourceRow key={s.id} name={s.name} symbol={s.status === "interrupted" ? "arrow.counterclockwise" : "rectangle.stack"} count={count(src)} selected={isSel(src)}
                    onClick={() => st().selectSource(src)}
                    onContext={(e) => openContextMenu(e, [
                      { title: "Session details", icon: "info.circle", onSelect: () => { st().setPane("sessions"); st().popTo("sessions", 0); st().push("sessions", { kind: "sessionDetail", id: s.id }); } },
                      { title: "Rename…", icon: "pencil", onSelect: () => st().openModal({ kind: "rename", title: "Rename session", value: s.name, onSave: (name) => api.sessionRename({ id: s.id, name }).catch(st().fail) }) },
                      { kind: "divider" },
                      { title: "Delete session…", icon: "trash", destructive: true, onSelect: () => st().openModal({
                        kind: "confirm", title: "Delete this session?", message: "Frames, ratings and exports in this session are removed from the Mac.",
                        confirmTitle: "Delete", destructive: true, cancelTitle: "Keep",
                        onConfirm: () => api.sessionDelete({ id: s.id }).then(() => st().selectSource({ kind: "collection", id: "builtin.all" })),
                      }) },
                    ])} />
                );
              })}
            </Section>
            {sources.cameras.length ? (
              <Section title="Cameras">
                {sources.cameras.map((c) => {
                  const src: LibrarySource = { kind: "camera", id: c.id };
                  return <SourceRow key={c.id} name={cameraDisplayName(c)} symbol="camera" count={count(src)} selected={isSel(src)} onClick={() => st().selectSource(src)} />;
                })}
              </Section>
            ) : null}
          </>
        ) : null}
      </div>
    </nav>
  );
}
