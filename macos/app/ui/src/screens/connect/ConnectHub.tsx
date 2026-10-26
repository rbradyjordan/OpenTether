import { useEffect, useState } from "react";
import { api, cameraDisplayName, TRANSPORT_NAMES, type FtpReceiverStatus, type KnownCamera, type SessionSummary } from "../../api";
import { useApp } from "../../state/store";
import { Screen, useStack } from "../routes";
import { ActionCard, IconTile, SectionCard } from "../../components/common";
import { Icon } from "../../components/Icon";
import { relativeTime } from "../../lib/format";

/** Pick a connection path; each card shows a live badge once a camera is actually visible on it. */
export function ConnectHub() {
  const { push } = useStack();
  const sessions = useApp((s) => s.sessions);
  const interrupted = sessions.filter((x) => x.session.status === "interrupted");
  const [usbVisible, setUsbVisible] = useState(false);
  const [wifiVisible, setWifiVisible] = useState(false);
  const [ftp, setFtp] = useState<FtpReceiverStatus | null>(null);
  const [known, setKnown] = useState<KnownCamera[]>([]);

  useEffect(() => {
    api.usbDevices().then((d) => setUsbVisible(d.length > 0));
    api.ftpReceiverStatus().then(setFtp);
    api.knownCameras().then(setKnown);
    const un = [
      api.on("usb:devices", (d) => setUsbVisible(d.length > 0)),
      api.on("discovery:cameras", (c) => setWifiVisible(c.length > 0)),
      api.on("ftp:status", setFtp),
    ];
    return () => un.forEach((f) => f());
  }, []);
  const ftpLive = !!ftp?.running && ftp.clients > 0;

  return (
    <Screen
      title="Connect"
      readable
      trailing={<button className="btn secondary small" onClick={() => useApp.getState().openModal({ kind: "newSession" })}><Icon name="plus" size={13} /> New session</button>}
    >
      <div className="stack">
        <p className="t-callout" style={{ margin: "0 4px 4px" }}>Pick how your camera talks to the Mac. USB-C is the fastest and most reliable.</p>
        {interrupted[0] ? <ResumeBanner summary={interrupted[0]} /> : null}
        <div className="arrive" style={{ animationDelay: "0ms" }}>
          <ActionCard title="USB-C" subtitle="Plug the camera straight into the Mac." icon="cable.connector" badge={usbVisible ? "Camera found" : null} live={usbVisible} onClick={() => push({ kind: "usb" })} />
        </div>
        <div className="arrive" style={{ animationDelay: "50ms" }}>
          <ActionCard title="Wi-Fi" subtitle="Join the camera's network, then pick it here." icon="wifi" badge={wifiVisible ? "Camera found" : null} live={wifiVisible} onClick={() => push({ kind: "wifi" })} />
        </div>
        <div className="arrive" style={{ animationDelay: "100ms" }}>
          <ActionCard title="FTP" subtitle="The camera sends each photo to the Mac as you shoot." icon="arrow.down.doc" badge={ftpLive ? "Receiving" : null} live={ftpLive} onClick={() => push({ kind: "ftpReceiver" })} />
        </div>
        {known.length ? (
          <SectionCard title="Recent cameras" icon="clock" className="arrive">
            {known.slice(0, 4).map((k) => (
              <div key={k.camera.id} className="row">
                <div className="col fill" style={{ gap: 0 }}>
                  <span className="t-callout ink-0" style={{ fontWeight: 500 }}>{cameraDisplayName(k.camera)}</span>
                  <span className="t-hud ink-2">{[TRANSPORT_NAMES[k.camera.transport], k.host].filter(Boolean).join(" · ")}</span>
                </div>
                <span className="t-hud ink-2">{relativeTime(k.lastSeen)}</span>
              </div>
            ))}
          </SectionCard>
        ) : null}
        <ActionCard title="Camera setup guides" subtitle="The menu to change on Canon, Nikon, Sony, Fujifilm and more." icon="book.pages" onClick={() => push({ kind: "brandGuides" })} />
        <ActionCard
          title="No camera? Try a demo session"
          subtitle="Sample frames arrive as if you were shooting, so you can rate, apply looks and export."
          icon="play.rectangle"
          onClick={() => api.demoStart().then((st) => useApp.getState().activate(st)).catch(useApp.getState().fail)}
        />
      </div>
    </Screen>
  );
}

/** "Pick up where you left off": frame count and transport, one primary action. */
export function ResumeBanner({ summary }: { summary: SessionSummary }) {
  const s = summary.session;
  const st = useApp.getState;
  return (
    <div className="card tinted col" style={{ gap: 12 }}>
      <div className="row-top">
        <IconTile name="arrow.counterclockwise" active size={38} />
        <div className="col fill" style={{ gap: 1 }}>
          <span className="t-caption" style={{ color: "var(--accent)" }}>Pick up where you left off</span>
          <span className="t-headline">{s.name}</span>
          <span className="t-hud ink-1">{summary.counts.total} frames · {s.transport ? TRANSPORT_NAMES[s.transport] : "no camera"}</span>
        </div>
        <button className="icon-btn round" aria-label={`End ${s.name} without resuming`} title="End without resuming"
          onClick={() => api.sessionDismissInterrupted({ id: s.id }).then(() => st().refreshSessions())}>
          <Icon name="xmark" size={13} strokeWidth={2.4} />
        </button>
      </div>
      <button className="btn primary block" onClick={() => api.sessionResume({ id: s.id }).then((state) => st().activate(state)).catch(st().fail)}>
        <Icon name="play.fill" size={12} /> Resume session
      </button>
    </div>
  );
}
