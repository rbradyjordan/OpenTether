import { useEffect, useLayoutEffect, useRef, useState } from "react";
import {
  api, cameraDisplayName, Cap, hasCap, isLiveStatus, statusText, simulateDisconnect, type FolderDestination, type ShootState,
} from "../../api";
import { useApp, displayedItem } from "../../state/store";
import { Icon } from "../../components/Icon";
import { MenuButton, commandItems, type MenuItem } from "../../components/Menu";
import { StatusPill } from "../../components/shootbits";
import type { Tone } from "../../components/common";
import { commandsFor, runCommand } from "../../commands/dispatcher";
import { importFiles } from "../library/actions";
import { Canvas } from "./Canvas";
import { ExposureBar } from "./ExposureBar";
import { Filmstrip } from "./Filmstrip";
import { BottomBar } from "./BottomBar";
import { formatBytes } from "../../lib/format";

const SIDE_BY_SIDE = 900;

export function shootCameraName(shoot: ShootState): string {
  if (shoot.identity) return cameraDisplayName(shoot.identity);
  if (shoot.isDemo) return "Demo camera";
  return shoot.session.transport === "ftpPush" ? "FTP receiver" : "No camera";
}

/** The tethering screen: always dark, the photograph is the interface. Covers the window; ⌘-click the grid icon to go back. */
export function ShootScreen() {
  const shoot = useApp((s) => s.shoot);
  const ref = useRef<HTMLDivElement>(null);
  const [wide, setWide] = useState(true);
  const [folders, setFolders] = useState<FolderDestination[]>([]);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWide(el.clientWidth >= SIDE_BY_SIDE && el.clientWidth > el.clientHeight));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  useEffect(() => {
    api.folderDestinationsList().then(setFolders).catch(() => undefined);
  }, []);

  if (!shoot) return null;
  const disconnected = shoot.status.kind === "disconnected";
  return (
    <div className="shoot" ref={ref} aria-label="Shoot">
      {wide ? (
        <div className="shoot-wide">
          <div className="shoot-main">
            <ShootHeader shoot={shoot} />
            {shoot.restoreOffer ? <RestoreOfferBanner shoot={shoot} /> : null}
            <div className="shoot-stage">
              <Filmstrip vertical />
              <div className={`shoot-canvas${disconnected ? " dimmed" : ""}`}>
                <Canvas />
              </div>
            </div>
          </div>
          <aside className="shoot-panel">
            <div className="shoot-panel-scroll">
              {shoot.identity ? (
                <>
                  <div className="t-caption panel-caption">Exposure</div>
                  <ExposureBar grid />
                </>
              ) : null}
              <FrameInfo />
            </div>
            <BottomBar folders={folders} />
          </aside>
        </div>
      ) : (
        <div className="shoot-narrow">
          <ShootHeader shoot={shoot} />
          {shoot.restoreOffer ? <RestoreOfferBanner shoot={shoot} /> : null}
          <div className={`shoot-canvas${disconnected ? " dimmed" : ""}`}>
            <Canvas />
          </div>
          {shoot.identity ? <ExposureBar /> : null}
          <Filmstrip />
          <BottomBar folders={folders} />
        </div>
      )}
    </div>
  );
}

function FrameInfo() {
  const shoot = useApp((s) => s.shoot);
  const item = displayedItem(shoot);
  if (!item) return null;
  return (
    <>
      <div className="t-caption panel-caption">Frame</div>
      <div className="col" style={{ gap: 2, padding: "0 16px" }}>
        <span className="t-callout ink-0" style={{ fontWeight: 600 }}>{item.filename}</span>
        <span className="t-hud ink-1">#{item.sequence} · {formatBytes(item.bytes)} · {item.width}×{item.height}</span>
      </div>
    </>
  );
}

function ShootHeader({ shoot }: { shoot: ShootState }) {
  const st = useApp.getState;
  const tone: Tone = shoot.status.kind === "ready" || shoot.status.kind === "capturing" ? "ok"
    : shoot.status.kind === "disconnected" ? "danger" : shoot.status.kind === "ended" ? "neutral" : "warn";
  const transport = shoot.identity?.transport ?? shoot.session.transport;
  const transportIcon = transport === "usb" ? "cable.connector" : transport === "ftpPush" ? "arrow.down.doc" : transport ? "wifi" : null;
  const battery = shoot.properties.find((p) => p.property === "batteryLevel")?.display ?? null;
  const detail = isLiveStatus(shoot.status) ? null : statusText(shoot.status);

  const sessionMenu = (): MenuItem[] => {
    const items: MenuItem[] = [
      { title: "Export progress", icon: "arrow.up.doc", onSelect: () => st().openModal({ kind: "exportProgress", sessionId: shoot.session.id }) },
      { title: "Rename session…", icon: "pencil", onSelect: () => st().openModal({
        kind: "rename", title: "Rename session", value: shoot.session.name,
        onSave: (name) => api.sessionRename({ id: shoot.session.id, name }).catch(st().fail),
      }) },
      { title: "Import files…", icon: "square.and.arrow.down", onSelect: () => importFiles(shoot.session.id) },
      { title: "Diagnostics", icon: "stethoscope", onSelect: () => st().openModal({ kind: "diagnosticsSheet", wired: transport === "usb" }) },
    ];
    if (shoot.status.kind === "disconnected") items.push({ title: "Reconnect", icon: "arrow.clockwise", onSelect: () => st().showReconnect() });
    if (api.kind === "mock" && shoot.identity && shoot.status.kind === "ready") {
      items.push({ title: "Simulate a dropped link (demo)", icon: "bolt.slash", onSelect: () => simulateDisconnect() });
    }
    items.push({ kind: "divider" });
    items.push(...commandItems(commandsFor("shoot", []).filter((c) => c.group === "session"), (c) => runCommand(c, [], "shoot")));
    return items;
  };

  return (
    <div className="shoot-header">
      <StatusPill
        tone={tone}
        title={shootCameraName(shoot)}
        transportIcon={transportIcon}
        battery={battery}
        downloads={shoot.downloadsInFlight}
        detail={detail}
        onClick={() => {
          if (shoot.status.kind === "disconnected" || shoot.status.kind === "reconnecting") st().showReconnect();
          else st().openModal({ kind: "diagnosticsSheet", wired: transport === "usb" });
        }}
      />
      <span className="t-hud ink-2 truncate" style={{ maxWidth: 300 }}>{shoot.session.name}</span>
      <span className="spacer" />
      {shoot.identity && !hasCap(shoot.identity.capabilities, Cap.remoteCapture) ? <span className="pill neutral">Import only</span> : null}
      <button className="icon-btn glass-round" title="Back to library, keep shooting" aria-label="Back to library, keep shooting" onClick={() => st().setShowShoot(false)}>
        <Icon name="rectangle.3.group" size={17} />
      </button>
      <button className="btn secondary quiet" style={{ color: "var(--ink-0)" }} onClick={() => runCommand({ id: "session.end", title: "End session", symbol: "stop.circle", group: "session" }, [], "shoot")}>
        End
      </button>
      <MenuButton className="icon-btn" label="Session menu" title="Session menu" items={sessionMenu} align="right" minWidth={230}>
        <Icon name="ellipsis.circle" size={20} />
      </MenuButton>
    </div>
  );
}

/** "Use last time's look Warm Portrait? Yes / No". */
function RestoreOfferBanner({ shoot }: { shoot: ShootState }) {
  const offer = shoot.restoreOffer;
  if (!offer) return null;
  return (
    <div className="restore-banner">
      <Icon name="camera.filters" size={15} className="c-accent" />
      <span className="t-callout ink-0 truncate">Use last time's look {offer.lookName}?</span>
      <span className="spacer" />
      <button className="btn plain small" onClick={() => api.shootRestoreOffer({ accept: true })}>Yes</button>
      <button className="btn plain small quiet" onClick={() => api.shootRestoreOffer({ accept: false })}>No</button>
    </div>
  );
}
