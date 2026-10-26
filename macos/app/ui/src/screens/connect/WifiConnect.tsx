import { useEffect, useState } from "react";
import { api, VENDOR_NAMES, type DiscoveredCamera, type DiscoveryMethod, type NetworkInfo } from "../../api";
import { useApp } from "../../state/store";
import { Screen, useStack } from "../routes";
import { SectionCard, Spinner } from "../../components/common";
import { Icon } from "../../components/Icon";
import { ConnectingProgress, SessionPicker, useConnectProgress } from "./shared";

const METHOD_LABEL: Record<DiscoveryMethod, string> = { ssdp: "SSDP", bonjour: "Bonjour", fujiUDP: "Fuji", ricohHTTP: "HTTP", httpProbe: "HTTP", manual: "Manual" };

export function WifiConnect() {
  const { push } = useStack();
  const [cameras, setCameras] = useState<DiscoveredCamera[]>([]);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [net, setNet] = useState<NetworkInfo | null>(null);
  const [session, setSession] = useState<string | null>(null);
  const [connectingId, setConnectingId] = useState<string | null>(null);
  const progress = useConnectProgress();

  useEffect(() => {
    api.discoveryStart().then((d) => {
      setCameras(d.cameras);
      setErrors(d.errors);
    });
    api.networkInfo().then(setNet);
    const un = api.on("discovery:cameras", setCameras);
    return () => {
      un();
      api.discoveryStop();
    };
  }, []);

  const connect = async (c: DiscoveredCamera) => {
    setConnectingId(c.id);
    progress.begin();
    try {
      const st = await api.wifiConnect({ cameraId: c.id, sessionId: session });
      progress.dismiss();
      useApp.getState().activate(st);
    } catch {
      /* shown in the progress card */
    } finally {
      setConnectingId(null);
    }
  };

  const groups = new Map<string, DiscoveredCamera[]>();
  for (const c of cameras) groups.set(c.vendor ?? "~", [...(groups.get(c.vendor ?? "~") ?? []), c]);

  return (
    <Screen
      title="Wi-Fi"
      readable
      trailing={<button className="btn secondary small" onClick={() => useApp.getState().openModal({ kind: "manualIP" })}><Icon name="keyboard" size={13} /> Enter IP</button>}
    >
      <div className="stack">
        <SessionPicker value={session} onChange={setSession} />
        <SectionCard title="Current Wi-Fi" icon="wifi">
          {net?.ssid ? (
            <>
              <span className="t-title">{net.ssid}</span>
              {net.cameraNetworkVendor ? (
                <span className="row t-callout c-ok"><Icon name="checkmark.circle.fill" size={14} /> Looks like a {VENDOR_NAMES[net.cameraNetworkVendor]} camera network</span>
              ) : (
                <span className="row t-callout c-warn"><Icon name="info.circle" size={14} /> This does not look like a camera network. Join the camera's own Wi-Fi first.</span>
              )}
            </>
          ) : (
            <span className="t-callout">macOS does not share the network name with apps. Check the Wi-Fi menu in the menu bar: it should show the camera's network.</span>
          )}
          {net?.localAddresses.length ? <span className="t-hud ink-2">This Mac: {net.localAddresses.join(", ")}</span> : null}
          <span className="t-hud ink-2">Open Tether never joins a Wi-Fi network for you.</span>
          <button className="btn secondary small" style={{ alignSelf: "flex-start" }} onClick={() => api.openWifiSettings()}>
            <Icon name="arrow.up.forward.app" size={13} /> Open Wi-Fi Settings
          </button>
        </SectionCard>
        {progress.progress ? <ConnectingProgress progress={progress.progress} onDismiss={progress.dismiss} /> : null}
        {cameras.length === 0 ? (
          <SectionCard title="Looking on this network" icon="dot.radiowaves.left.and.right">
            <div className="row"><Spinner small /><span className="t-callout ink-0">Listening for SSDP, Bonjour, Fujifilm and Ricoh announcements…</span></div>
            <span className="t-callout">Nothing yet? Make sure the camera is in its Wi-Fi remote / PC-connection mode, then use Enter IP if it still does not appear.</span>
            {Object.entries(errors).map(([k, v]) => <span key={k} className="t-hud c-warn">{k}: {v}</span>)}
          </SectionCard>
        ) : (
          [...groups.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([vendor, list]) => (
            <SectionCard key={vendor} title={vendor === "~" ? "Unknown brand" : VENDOR_NAMES[vendor as keyof typeof VENDOR_NAMES]} icon="camera" className="arrive">
              {list.map((c) => (
                <div key={c.id} className="row">
                  <div className="col fill" style={{ gap: 2 }}>
                    <span className="t-body" style={{ fontWeight: 500 }}>{c.name}</span>
                    <span className="row" style={{ gap: 6 }}>
                      <span className="t-hud ink-2">{c.host}:{c.port}</span>
                      <span className="pill neutral" style={{ fontSize: 10, padding: "0 6px" }} aria-label={`Found via ${METHOD_LABEL[c.method]}`}>{METHOD_LABEL[c.method]}</span>
                      {!c.isControllable ? <span className="pill warn" style={{ fontSize: 10, padding: "0 6px" }}>import only</span> : null}
                    </span>
                  </div>
                  {connectingId === c.id ? <Spinner small /> : (
                    <button className="btn primary small" disabled={!!connectingId} onClick={() => connect(c)} aria-label={`Connect to ${c.name}`}>Connect</button>
                  )}
                </div>
              ))}
            </SectionCard>
          ))
        )}
        <button className="action-card" onClick={() => push({ kind: "diagnostics", wired: false })}>
          <Icon name="stethoscope" size={16} />
          <span className="fill">Run the wireless diagnostic</span>
          <Icon name="chevron.right" size={13} className="ink-2" />
        </button>
      </div>
    </Screen>
  );
}
