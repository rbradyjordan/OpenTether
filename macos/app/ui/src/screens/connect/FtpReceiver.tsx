import { useEffect, useState } from "react";
import { api, type CameraVendor, VENDOR_NAMES, type FtpReceiverStatus } from "../../api";
import { useApp } from "../../state/store";
import { Screen } from "../routes";
import { Labeled, Select, TextField, Toggle } from "../../components/controls";
import { SectionCard } from "../../components/common";
import { Icon } from "../../components/Icon";
import { SessionPicker } from "./shared";
import { FTP_CAPABLE, ftpInstructions } from "./guideData";
import { formatBytes, formatTime } from "../../lib/format";

/** The camera uploads each photo to the Mac over Wi-Fi as you shoot. */
export function FtpReceiver() {
  const settings = useApp((s) => s.settings);
  const [status, setStatus] = useState<FtpReceiverStatus | null>(null);
  const [session, setSession] = useState<string | null>(null);
  const [username, setUsername] = useState(settings?.ftpUsername ?? "");
  const [password, setPassword] = useState(settings?.ftpPassword ?? "");
  const [port, setPort] = useState(String(settings?.ftpPort ?? 2121));
  const [vendor, setVendor] = useState<CameraVendor>("canon");
  const [starting, setStarting] = useState(false);

  useEffect(() => {
    api.ftpReceiverStatus().then(setStatus);
    const un = [api.on("ftp:status", setStatus), api.on("ftp:file", () => api.ftpReceiverStatus().then(setStatus))];
    return () => un.forEach((f) => f());
  }, []);

  const changed = settings && (username !== settings.ftpUsername || password !== settings.ftpPassword || port !== String(settings.ftpPort));
  const address = status?.addresses[0] ?? "<Mac IP>";
  const boundPort = status?.boundPort ?? Number(port);

  const start = async () => {
    setStarting(true);
    try {
      const st = await api.ftpReceiverStartSession({ sessionId: session });
      useApp.getState().activate(st);
    } catch (e) {
      useApp.getState().fail(e);
    } finally {
      setStarting(false);
    }
  };

  return (
    <Screen title="FTP push" readable>
      <div className="stack">
        <p className="t-callout" style={{ margin: "0 4px" }}>Your camera uploads each photo to the Mac over Wi-Fi as you shoot.</p>
        <SessionPicker value={session} onChange={setSession} />
        <SectionCard title="1 · Login the camera uses" icon="person.badge.key">
          <Labeled label="Username"><TextField value={username} onChange={setUsername} label="FTP username" /></Labeled>
          <div className="row gap-m">
            <Labeled label="Password" style={{ flex: 1 }}><TextField mono value={password} onChange={setPassword} label="FTP password" /></Labeled>
            <Labeled label="Port" style={{ width: 110 }}><TextField mono value={port} onChange={(v) => setPort(v.replace(/\D/g, ""))} label="FTP port" /></Labeled>
          </div>
          {changed ? (
            <button className="btn secondary small arrive" style={{ alignSelf: "flex-start" }} disabled={!username || !password}
              onClick={() => useApp.getState().updateSettings({ ftpUsername: username, ftpPassword: password, ftpPort: Number(port) || 2121 })}>
              Save login
            </button>
          ) : null}
        </SectionCard>
        <SectionCard title="2 · Set up the camera" icon="camera.badge.ellipsis">
          <Select<CameraVendor> label="Brand" value={vendor} style={{ maxWidth: 260 }} options={FTP_CAPABLE.map((v) => ({ value: v, label: VENDOR_NAMES[v] }))} onChange={setVendor} />
          <span className="t-callout selectable">{ftpInstructions(vendor, address, boundPort, status?.username ?? username)}</span>
        </SectionCard>
        <button className="btn primary large block" disabled={starting} onClick={start}>
          <Icon name="play.fill" size={13} /> 3 · Start shooting
        </button>
        <SectionCard title="FTP server on this Mac" icon="antenna.radiowaves.left.and.right">
          <div className="row">
            <Icon name={status?.running ? "dot.radiowaves.left.and.right" : "pause.circle"} size={16} className={status?.running ? "c-ok" : "ink-1"} />
            <span className="t-callout fill" style={{ color: status?.running ? "var(--ok)" : "var(--ink-1)", fontWeight: 500 }}>{status?.running ? "Listening" : "Stopped"}</span>
            <Toggle label="FTP server" on={!!status?.running} onChange={(on) => (on ? api.ftpReceiverStart() : api.ftpReceiverStop()).then(setStatus)} />
          </div>
          {status?.running ? (
            <>
              <div className="row"><span className="fill t-callout">Address</span><span className="t-mono ink-0 selectable">{address}:{boundPort}</span></div>
              <div className="row"><span className="fill t-callout">Cameras connected</span><span className="num">{status.clients}</span></div>
            </>
          ) : null}
          {status?.lastError ? <span className="t-callout c-danger">{status.lastError}</span> : null}
        </SectionCard>
        <SectionCard title="Received files" icon="tray.and.arrow.down">
          {!status?.received.length ? (
            <span className="t-callout">Nothing received yet. Take a picture once the camera shows the FTP connection as OK.</span>
          ) : (
            status.received.slice(0, 30).map((f) => (
              <div key={f.id} className="row">
                <div className="col fill" style={{ gap: 0 }}>
                  <span className="t-callout ink-0">{f.name}</span>
                  <span className="t-hud ink-2">{formatBytes(f.bytes)} from {f.from} in {f.durationSeconds.toFixed(1)} s</span>
                </div>
                <span className="t-hud ink-2">{formatTime(f.at)}</span>
              </div>
            ))
          )}
        </SectionCard>
      </div>
    </Screen>
  );
}
