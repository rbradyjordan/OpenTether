import { useEffect, useRef, useState } from "react";
import type { Origin } from "../../state/types";
import { CaptureImage } from "../../components/media";
import { useOrigin } from "./origin";

/**
 * True black, image only. A hint fades after two seconds; clicks on the
 * picture show the filename; ← → step. The way out is holding "Hold to exit"
 * for 0.8 s (Esc also leaves, for the photographer at the keyboard).
 */
export function ClientReview({ origin, onClose }: { origin: Origin; onClose: () => void }) {
  const list = useOrigin(origin);
  const [hint, setHint] = useState(true);
  const [name, setName] = useState(false);
  const cur = list.current;
  useEffect(() => {
    const t = window.setTimeout(() => setHint(false), 2000);
    document.documentElement.requestFullscreen?.().catch(() => undefined);
    return () => {
      clearTimeout(t);
      if (document.fullscreenElement) document.exitFullscreen?.().catch(() => undefined);
    };
  }, []);
  const index = cur ? list.items.findIndex((i) => i.id === cur.id) : -1;
  return (
    <div className="client-review" onClick={(e) => {
      const x = e.clientX / window.innerWidth;
      if (x < 0.2 && index > 0) list.select(list.items[index - 1].id);
      else if (x > 0.8 && index < list.items.length - 1) list.select(list.items[index + 1].id);
      else setName((n) => !n);
    }}>
      {cur ? <CaptureImage key={cur.id} item={cur} variant="preview" look={list.look} fit="contain" lazy={false} /> : null}
      {name && cur ? <div className="client-name t-hud">{cur.filename}</div> : null}
      <HoldToExit onExit={onClose} />
      {hint ? <div className="client-hint t-hud">click the sides to step · click for name · hold Exit to leave</div> : null}
    </div>
  );
}

function HoldToExit({ onExit }: { onExit: () => void }) {
  const [holding, setHolding] = useState(false);
  const timer = useRef<number | null>(null);
  const start = () => {
    setHolding(true);
    timer.current = window.setTimeout(() => {
      setHolding(false);
      onExit();
    }, 800);
  };
  const cancel = () => {
    if (timer.current != null) clearTimeout(timer.current);
    timer.current = null;
    setHolding(false);
  };
  return (
    <button
      className={`hold-exit${holding ? " holding" : ""}`}
      aria-label="Exit client review"
      onClick={(e) => e.stopPropagation()}
      onMouseDown={(e) => { e.stopPropagation(); start(); }}
      onMouseUp={cancel}
      onMouseLeave={cancel}
      onKeyDown={(e) => { if (e.key === "Enter") onExit(); }}
    >
      <svg width="22" height="22" viewBox="0 0 22 22" aria-hidden>
        <circle cx="11" cy="11" r="9" stroke="rgba(242,244,247,0.25)" strokeWidth="2" fill="none" />
        <circle cx="11" cy="11" r="9" stroke="var(--accent)" strokeWidth="2" fill="none" strokeLinecap="round" strokeDasharray={56.5}
          strokeDashoffset={holding ? 0 : 56.5} transform="rotate(-90 11 11)" style={{ transition: holding ? "stroke-dashoffset 800ms linear" : "stroke-dashoffset 150ms ease-out" }} />
        <path d="M8 8l6 6M14 8l-6 6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
      </svg>
      {holding ? "Keep holding" : "Hold to exit"}
    </button>
  );
}
