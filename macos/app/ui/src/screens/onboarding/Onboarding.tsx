import { useEffect, useState } from "react";
import { api, type PermissionKind, type PermissionState } from "../../api";
import { useApp } from "../../state/store";
import { Icon } from "../../components/Icon";
import { IconTile } from "../../components/common";
import brandIcon from "../../assets/brand-icon.png";

interface Page {
  title: string;
  line: string;
  symbol: string;
  glow: string;
  hero?: boolean;
  permissions?: boolean;
}

const PAGES: Page[] = [
  { title: "Shoot tethered,\nreview live", line: "Every frame lands on your Mac the moment you take it.", symbol: "camera.aperture", glow: "#4A9DFF", hero: true },
  { title: "Nothing happens behind your back", line: "Open Tether never joins a network, uploads a photo or reads your library without asking.", symbol: "hand.raised.fill", glow: "#7B6CFF" },
  { title: "Two quick permissions", line: "Each is optional. You can allow them now or when a feature needs them.", symbol: "lock.shield.fill", glow: "#37C6C0", permissions: true },
];

function PermissionRow({ title, symbol, state, onAllow }: { title: string; symbol: string; state: PermissionState; onAllow: () => void }) {
  const done = state === "granted";
  return (
    <div className="card row gap-m" style={{ padding: "10px 16px" }}>
      <IconTile name={symbol} size={34} />
      <span className="t-body fill" style={{ fontWeight: 500 }}>{title}</span>
      {done ? (
        <span className="row c-ok t-callout" style={{ fontWeight: 600 }}><Icon name="checkmark.circle.fill" size={15} /> Allowed</span>
      ) : (
        <button className="btn secondary small" onClick={onAllow}>{state === "denied" ? "Open Settings" : "Allow"}</button>
      )}
    </div>
  );
}

/** Three pages, one line each; the last asks for the optional permissions. */
export function Onboarding() {
  const [page, setPage] = useState(0);
  const [perms, setPerms] = useState<Record<PermissionKind, PermissionState>>({ localNetwork: "notDetermined", photos: "notDetermined" });
  useEffect(() => {
    api.permissionsStatus().then(setPerms).catch(() => undefined);
  }, []);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "ArrowRight" || (e.key === "Enter" && !(e.target instanceof HTMLButtonElement))) next();
      if (e.key === "ArrowLeft") setPage((p) => Math.max(0, p - 1));
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });
  const last = page === PAGES.length - 1;
  const next = () => (last ? useApp.getState().updateSettings({ hasOnboarded: true }) : setPage((p) => p + 1));
  const ask = (kind: PermissionKind) => api.permissionsRequest({ kind }).then((s) => setPerms((p) => ({ ...p, [kind]: s })));
  const p = PAGES[page];

  return (
    <div className="onboarding">
      <div className="onboarding-page" key={page}>
        <div className="onboarding-hero">
          {p.hero ? (
            <img src={brandIcon} alt="" className="onboarding-icon" draggable={false} />
          ) : (
            <span className="onboarding-medallion" style={{ background: `${p.glow}38`, borderColor: `${p.glow}66` }}>
              <Icon name={p.symbol} size={52} strokeWidth={1.4} />
            </span>
          )}
        </div>
        <h1 className="t-display onboarding-title">{p.title}</h1>
        <p className="t-body ink-1" style={{ margin: 0 }}>{p.line}</p>
        {p.permissions ? (
          <div className="col" style={{ gap: 8, marginTop: 8 }}>
            <PermissionRow title="Local network" symbol="network" state={perms.localNetwork} onAllow={() => ask("localNetwork")} />
            <PermissionRow title="Save to Photos" symbol="photo.on.rectangle" state={perms.photos} onAllow={() => ask("photos")} />
            <span className="t-hud ink-2">The Mac never shares the Wi-Fi name with apps, so there is nothing to ask for it.</span>
          </div>
        ) : null}
      </div>
      <div className="onboarding-footer">
        <div className="page-progress" aria-label={`Page ${page + 1} of ${PAGES.length}`}>
          {PAGES.map((_, i) => (
            <span key={i} className={i === page ? "on" : ""} onClick={() => setPage(i)} />
          ))}
        </div>
        <button className="btn primary large block" onClick={next}>{last ? "Start shooting" : "Continue"}</button>
        {!last ? <button className="btn plain quiet small" onClick={() => useApp.getState().updateSettings({ hasOnboarded: true })}>Skip</button> : null}
      </div>
    </div>
  );
}
