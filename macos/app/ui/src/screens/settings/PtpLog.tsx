import { useEffect, useState } from "react";
import { api, type PtpLogLine } from "../../api";
import { useApp } from "../../state/store";
import { Screen } from "../routes";
import { Icon } from "../../components/Icon";
import { formatTime } from "../../lib/format";

const ARROW: Record<PtpLogLine["direction"], string> = { out: "→", in: "←", event: "⚡", note: "·" };

/** The last few hundred PTP exchanges, for bug reports. */
export function PtpLog() {
  const [lines, setLines] = useState<PtpLogLine[]>([]);
  useEffect(() => {
    const load = () => api.ptpLog().then(setLines);
    load();
    const t = window.setInterval(load, 2000);
    return () => clearInterval(t);
  }, []);
  const text = lines.map((l) => `${l.at} ${ARROW[l.direction]} ${l.text}`).join("\n");
  return (
    <Screen title="Camera conversation log" trailing={
      <button className="btn secondary small" disabled={!lines.length} onClick={() => navigator.clipboard?.writeText(text).then(() => useApp.getState().toast("Log copied", "doc.text"))}>
        <Icon name="doc.text" size={13} /> Copy
      </button>
    }>
      {lines.length ? (
        <pre className="xmp-preview selectable" style={{ maxHeight: "none" }}>
          {lines.map((l, i) => (
            <div key={i}>
              <span className="ink-2">{formatTime(l.at)} </span>
              <span className={l.direction === "event" ? "c-accent" : l.direction === "note" ? "ink-1" : "ink-0"}>{ARROW[l.direction]} {l.text}</span>
            </div>
          ))}
        </pre>
      ) : (
        <div className="t-callout">Nothing logged yet. Connect a camera and the PTP conversation shows up here.</div>
      )}
    </Screen>
  );
}
