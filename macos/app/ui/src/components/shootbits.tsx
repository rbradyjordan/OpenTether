import { useEffect, useRef, useState } from "react";
import { Icon } from "./Icon";
import { Spinner, type Tone } from "./common";

/** One line: dot · camera model · transport glyph · battery · "3 ↓". Clicking opens diagnostics or reconnect. */
export function StatusPill({
  tone, title, transportIcon, battery, downloads, detail, onClick,
}: { tone: Tone; title: string; transportIcon?: string | null; battery?: string | null; downloads?: number; detail?: string | null; onClick?: () => void }) {
  const color = tone === "ok" ? "var(--ok)" : tone === "warn" ? "var(--warn)" : tone === "danger" ? "var(--danger)" : "var(--ink-2)";
  return (
    <button className="status-pill glass" onClick={onClick} title="Connection details">
      <span className="dot" style={{ background: color }} />
      <span className="t-hud ink-0 truncate" style={{ maxWidth: 220 }}>{title}</span>
      {transportIcon ? <Icon name={transportIcon} size={13} className="ink-1" /> : null}
      {battery ? (
        <span className="row t-hud ink-1" style={{ gap: 3 }}>
          <Icon name="battery.75percent" size={15} strokeWidth={1.5} />
          {battery}
        </span>
      ) : null}
      {downloads && downloads > 0 ? <span className="t-hud c-accent">{downloads} ↓</span> : null}
      {detail ? <span className="t-hud truncate" style={{ color, maxWidth: 260 }}>{detail}</span> : null}
    </button>
  );
}

/**
 * The signature shutter control. Click: inner disc dips and a ring pulses out
 * (capture with AF). Hold for 0.45 s: the disc turns hollow and reads "No AF";
 * release fires without autofocus.
 */
export function CaptureRing({ enabled, busy, onCapture, pulse }: { enabled: boolean; busy: boolean; onCapture: (autofocus: boolean) => void; pulse: number }) {
  const [pressed, setPressed] = useState(false);
  const [holding, setHolding] = useState(false);
  const [pulses, setPulses] = useState<number[]>([]);
  const timer = useRef<number | null>(null);
  const holdingRef = useRef(false);

  useEffect(() => {
    if (pulse === 0) return;
    const id = pulse;
    setPulses((p) => (p.includes(id) ? p : [...p, id]));
    const t = window.setTimeout(() => setPulses((p) => p.filter((x) => x !== id)), 950);
    return () => clearTimeout(t);
  }, [pulse]);

  function down(e: React.MouseEvent) {
    if (!enabled || e.button !== 0) return;
    setPressed(true);
    holdingRef.current = false;
    timer.current = window.setTimeout(() => {
      holdingRef.current = true;
      setHolding(true);
    }, 450);
  }
  function up(fire: boolean) {
    if (timer.current != null) clearTimeout(timer.current);
    timer.current = null;
    const wasHolding = holdingRef.current;
    const wasPressed = pressed;
    setPressed(false);
    setHolding(false);
    holdingRef.current = false;
    if (fire && wasPressed && enabled) onCapture(!wasHolding);
  }

  return (
    <button
      type="button"
      className={`capture-ring${enabled ? "" : " disabled"}${pressed ? " pressed" : ""}${holding ? " holding" : ""}`}
      aria-label="Shutter"
      title="Capture (Space) · hold for no AF"
      aria-disabled={!enabled}
      onMouseDown={down}
      onMouseUp={() => up(true)}
      onMouseLeave={() => up(false)}
      onKeyDown={(e) => {
        if (e.key === "Enter") onCapture(true);
      }}
    >
      {pulses.map((p) => (
        <span key={p} className="capture-pulse" />
      ))}
      <span className="capture-outer" />
      <span className="capture-disc" />
      {holding ? <span className="capture-noaf t-hud">No AF</span> : null}
      {busy ? <span className="capture-busy"><Spinner small /></span> : null}
    </button>
  );
}

/** The iOS "auto-import" stand-in for connections with no remote shutter. */
export function AutoImportBadge({ live }: { live: boolean }) {
  return (
    <div className="col" style={{ alignItems: "center", gap: 4 }} aria-label="Auto-import. Shoot on the camera; frames arrive here.">
      <span className="icon-btn glass-round" style={{ width: 56, height: 56, color: live ? "var(--accent)" : "var(--ink-2)", animation: live ? "pulse 1.6s ease-in-out infinite" : undefined }}>
        <Icon name="arrow.down" size={22} strokeWidth={2.2} />
      </span>
      <span className="t-caption" style={{ color: "var(--ink-1)", textTransform: "none", letterSpacing: 0 }}>{live ? "Auto-import" : "Waiting"}</span>
    </div>
  );
}
