import { useEffect, useState } from "react";
import { api, VENDOR_NAMES, type UsbAuthorization, type UsbCandidate } from "../../api";
import { useApp } from "../../state/store";
import { Screen, useStack } from "../routes";
import { SectionCard, Spinner } from "../../components/common";
import { Icon } from "../../components/Icon";
import { ConnectingProgress, SessionPicker, useConnectProgress } from "./shared";

const hex = (n: number) => n.toString(16).toUpperCase().padStart(4, "0");

export function UsbConnect() {
  const { push } = useStack();
  const [devices, setDevices] = useState<UsbCandidate[]>([]);
  const [auth, setAuth] = useState<UsbAuthorization | null>(null);
  const [session, setSession] = useState<string | null>(null);
  const [connecting, setConnecting] = useState(false);
  const progress = useConnectProgress();

  useEffect(() => {
    api.usbAuthorization().then(setAuth);
    api.usbDevices().then(setDevices);
    return api.on("usb:devices", setDevices);
  }, []);

  const connect = async (d: UsbCandidate) => {
    setConnecting(true);
    progress.begin();
    try {
      const st = await api.usbConnect({ candidateId: d.id, sessionId: session });
      progress.dismiss();
      useApp.getState().activate(st);
    } catch {
      /* the progress card shows the failure */
    } finally {
      setConnecting(false);
    }
  };

  return (
    <Screen title="USB-C" readable>
      <div className="stack">
        <SessionPicker value={session} onChange={setSession} />
        <SectionCard title="Permissions" icon="lock.shield">
          <div className="row">
            <Icon name={auth?.canSendPTP ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"} size={16} className={auth?.canSendPTP ? "c-ok" : "c-warn"} />
            <span className="t-callout ink-0 fill">{auth?.summary ?? "Checking…"}</span>
            {auth && !auth.canSendPTP ? (
              <button className="btn secondary small" onClick={() => api.usbRequestAuthorization().then(setAuth)}>Allow</button>
            ) : null}
          </div>
        </SectionCard>
        {progress.progress ? <ConnectingProgress progress={progress.progress} onDismiss={progress.dismiss} /> : null}
        <SectionCard title="Cameras on the cable" icon="camera">
          {devices.length === 0 ? (
            <div className="col" style={{ gap: 6 }}>
              <div className="row"><Spinner small /> <span className="t-callout ink-0">Looking for a camera…</span></div>
              <span className="t-callout">Switch the camera on, set its USB mode to PC / PTP / Tether, and use a data-capable cable straight into the Mac (not a hub). Quit Image Capture, Photos and EOS Utility, which hold the camera.</span>
              <span className="row t-callout ink-0"><Icon name="cable.connector" size={14} /> If your camera doesn't appear, unplug the cable and plug it back in.</span>
            </div>
          ) : (
            devices.map((d) => (
              <div key={d.id} className="row">
                <div className="col fill" style={{ gap: 0 }}>
                  <span className="t-body" style={{ fontWeight: 500 }}>{d.name}</span>
                  <span className="t-hud ink-2 truncate">{VENDOR_NAMES[d.vendorGuess]} · {hex(d.usbVendorId)}:{hex(d.usbProductId)}{d.serialNumber ? ` · ${d.serialNumber}` : ""}</span>
                  {d.vendorGuess === "ricoh" ? <span className="t-hud c-warn">Import only over USB for this brand</span> : null}
                </div>
                <button className="btn primary" disabled={connecting || !auth?.canSendPTP} onClick={() => connect(d)} aria-label={`Connect to ${d.name}`}>Connect</button>
              </div>
            ))
          )}
        </SectionCard>
        <button className="action-card" onClick={() => push({ kind: "diagnostics", wired: true })}>
          <Icon name="stethoscope" size={16} />
          <span className="fill">Something wrong? Run the cable diagnostic</span>
          <Icon name="chevron.right" size={13} className="ink-2" />
        </button>
        <button className="link t-callout" style={{ alignSelf: "flex-start" }} onClick={() => push({ kind: "brandGuides" })}>Camera menu settings for USB tethering</button>
      </div>
    </Screen>
  );
}
