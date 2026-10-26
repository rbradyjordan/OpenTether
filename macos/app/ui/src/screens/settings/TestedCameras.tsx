import { useState } from "react";
import { Screen } from "../routes";
import { Icon } from "../../components/Icon";

interface Tested { vendor: string; model: string; transports: string[]; status: string; notes: string }

/** The compatibility list, shipped with the app (same as iOS). */
const LIST: Tested[] = [
  { vendor: "Canon", model: "EOS R5 / R6 / R6 II", transports: ["usb", "ptpip"], status: "expected", notes: "PC / EOS Utility mode" },
  { vendor: "Nikon", model: "Z 6II / Z 7II / Z 8", transports: ["usb", "ptpip"], status: "expected", notes: "USB power delivery off" },
  { vendor: "Sony", model: "α7 IV / α7R V / α1", transports: ["usb", "ptpip"], status: "expected", notes: "PC Remote, single session" },
  { vendor: "Fujifilm", model: "X-T5 / X-H2 / GFX 100 II", transports: ["usb", "ptpip"], status: "expected", notes: "USB Tether Shooting Auto" },
  { vendor: "Ricoh", model: "GR III / GR IIIx", transports: ["ricohHTTP"], status: "expected", notes: "Wi-Fi only" },
  { vendor: "Leica", model: "SL2 / Q3 / M11", transports: ["usb"], status: "expected", notes: "USB mode PTP" },
  { vendor: "OM System", model: "OM-1 / OM-5", transports: ["usb"], status: "expected", notes: "PC (Tether) mode" },
  { vendor: "Panasonic", model: "S5 II / GH6", transports: ["usb"], status: "expected", notes: "USB Mode PC(Tether)" },
  { vendor: "Pentax", model: "K-1 II / K-3 III / KP", transports: ["usb"], status: "expected", notes: "USB Connection: PTP; import, capture if offered" },
  { vendor: "Sigma", model: "fp / fp L / BF", transports: ["usb"], status: "expected", notes: "USB Mode: Camera Control" },
  { vendor: "Hasselblad", model: "X2D / X1D II / 907X", transports: ["usb"], status: "expected", notes: "USB: PTP; import" },
  { vendor: "GoPro", model: "HERO9 – HERO13", transports: ["wifi"], status: "expected", notes: "Open GoPro API; photo mode" },
  { vendor: "Ricoh", model: "Theta X / Z1 / SC2", transports: ["wifi"], status: "expected", notes: "Open Spherical Camera API" },
  { vendor: "Insta360", model: "OSC-capable bodies", transports: ["wifi"], status: "expected", notes: "Open Spherical Camera API" },
  { vendor: "Canon", model: "PowerShot (G series)", transports: ["usb"], status: "expected", notes: "Import as you shoot" },
  { vendor: "Sony", model: "RX100 / RX10 / ZV (not PC Remote)", transports: ["usb"], status: "expected", notes: "Import as you shoot; PC Remote for control" },
  { vendor: "Any brand", model: "PTP over USB", transports: ["usb"], status: "expected", notes: "Import as you shoot" },
];

const color = (s: string) => (s === "verified" || s === "works" ? "var(--ok)" : s === "partial" || s === "beta" ? "var(--warn)" : "var(--ink-1)");

export function TestedCameras() {
  const [q, setQ] = useState("");
  const filtered = LIST.filter((c) => `${c.vendor} ${c.model} ${c.notes}`.toLowerCase().includes(q.trim().toLowerCase()));
  const vendors = [...new Set(filtered.map((c) => c.vendor))].sort();
  return (
    <Screen title="Tested cameras" readable trailing={
      <div className="search-field" style={{ width: 200 }}>
        <Icon name="magnifyingglass" size={13} className="ink-2" />
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Model" aria-label="Search models" />
      </div>
    }>
      <div className="stack">
        {vendors.map((v) => (
          <div key={v} className="col" style={{ gap: 4 }}>
            <span className="t-caption">{v}</span>
            <div className="form-group" style={{ background: "var(--surface-2)", borderRadius: 12, padding: "2px 12px" }}>
              {filtered.filter((c) => c.vendor === v).map((c) => (
                <div key={c.model} className="col" style={{ gap: 1, padding: "8px 0", borderTop: "0.5px solid var(--hairline)" }}>
                  <div className="row">
                    <span className="t-body" style={{ fontWeight: 500 }}>{c.model}</span>
                    <span className="spacer" />
                    <span className="t-hud" style={{ color: color(c.status) }}>{c.status[0].toUpperCase() + c.status.slice(1)}</span>
                  </div>
                  <span className="t-hud ink-1">{c.transports.join(", ")}</span>
                  {c.notes ? <span className="t-hud ink-2">{c.notes}</span> : null}
                </div>
              ))}
            </div>
          </div>
        ))}
      </div>
    </Screen>
  );
}
