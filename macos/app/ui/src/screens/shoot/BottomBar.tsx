import { api, Cap, hasCap, isLiveStatus, isReady, type FolderDestination } from "../../api";
import { useApp, displayedItem } from "../../state/store";
import { Icon } from "../../components/Icon";
import { MenuButton, commandItems, type MenuItem } from "../../components/Menu";
import { CaptureRing, AutoImportBadge } from "../../components/shootbits";
import { ReviewRow } from "../../components/review";
import { commandsFor, runCommand, openExport } from "../../commands/dispatcher";

/** Rating with Reject / Pick flanking it, then the capture ring with Looks and Export beside it and the rest in More. */
export function BottomBar({ folders }: { folders: FolderDestination[] }) {
  const shoot = useApp((s) => s.shoot);
  const pulse = useApp((s) => s.capturePulse);
  useApp((s) => s.undo);
  if (!shoot) return null;
  const st = useApp.getState;
  const item = displayedItem(shoot);
  const ready = shoot.items.filter(isReady);
  const canCapture = !!shoot.identity && hasCap(shoot.identity.capabilities, Cap.remoteCapture);
  const live = isLiveStatus(shoot.status);
  const ids = item ? [item.id] : [];
  const hotFolder = shoot.session.routing.liveFolderId;

  const more = (): MenuItem[] => {
    const items: MenuItem[] = [];
    if (ready.length >= 2) {
      const other = ready.filter((i) => i.id !== item?.id && i.kind !== "raw").at(-1) ?? ready.find((i) => i.id !== item?.id);
      items.push({ title: "Compare", icon: "rectangle.split.2x1", onSelect: () => st().openModal({ kind: "compare", origin: "shoot", ids: [item?.id, other?.id].filter((x): x is string => !!x) }) });
    }
    if (ready.length) items.push({ title: "Client review", icon: "person.crop.rectangle", shortcut: "⇧R", onSelect: () => st().openModal({ kind: "clientReview", origin: "shoot" }) });
    items.push({ title: "Export progress", icon: "arrow.up.doc", onSelect: () => st().openModal({ kind: "exportProgress", sessionId: shoot.session.id }) });
    items.push({
      kind: "submenu",
      title: hotFolder ? `Hot folder: ${folders.find((f) => f.id === hotFolder)?.name ?? "folder"}` : "Hot folder",
      icon: "folder.badge.gearshape",
      items: [
        { title: "Off", checked: !hotFolder, onSelect: () => api.shootSetRouting({ routing: { ...shoot.session.routing, liveFolderId: null } }) },
        ...folders.map((f): MenuItem => ({ title: f.name, checked: hotFolder === f.id, onSelect: () => api.shootSetRouting({ routing: { ...shoot.session.routing, liveFolderId: f.id } }) })),
        ...(folders.length ? [] : [{ kind: "header" as const, title: "Add folders in Settings › Saved folders" }]),
      ],
    });
    items.push({ kind: "divider" });
    items.push(...commandItems(commandsFor("shoot", ids), (c) => runCommand(c, ids, "shoot"), ["select.", "view.", "camera.", "session.", "export.again", "flag.", "rate."]));
    return items;
  };

  return (
    <div className="shoot-bottom">
      <div className="review-row-wrap">
        {item && isReady(item) ? (
          <ReviewRow item={item} size={24} onRate={(n) => st().rate([item.id], n)} onFlag={(f) => st().flag([item.id], f)} />
        ) : (
          <div style={{ height: 38 }} />
        )}
      </div>
      <div className="capture-row">
        <button className="tool" onClick={() => st().openModal({ kind: "looks" })} aria-label="Looks">
          <span className="icon-btn glass-round"><Icon name="camera.filters" size={18} /></span>
          Looks
        </button>
        <span className="spacer" />
        {canCapture ? (
          <CaptureRing enabled={live} busy={shoot.status.kind === "capturing"} pulse={pulse} onCapture={(af) => st().capture(af)} />
        ) : (
          <AutoImportBadge live={live} />
        )}
        <span className="spacer" />
        <div className="row" style={{ gap: 0 }}>
          <button className="tool" disabled={!ready.length} onClick={() => openExport("shoot", ids)} aria-label="Export" title="Export (⌘E)">
            <span className="icon-btn glass-round"><Icon name="square.and.arrow.up" size={18} /></span>
            Export
          </button>
          <MenuButton className="tool" label="More actions" items={more} align="right" minWidth={240}>
            <span className="icon-btn glass-round"><Icon name="ellipsis" size={18} /></span>
            More
          </MenuButton>
        </div>
      </div>
    </div>
  );
}
