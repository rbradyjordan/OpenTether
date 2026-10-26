import { useEffect, useRef, useState } from "react";
import { Cap, hasCap, isLiveStatus, statusText, type CaptureItem } from "../../api";
import { useApp, displayedItem } from "../../state/store";
import { CaptureImage } from "../../components/media";
import { EmptyState, ProgressBar, Spinner, TonePill } from "../../components/common";
import { Icon } from "../../components/Icon";
import type { FocusIndicator } from "../../state/types";

/** Live view when it's on, otherwise the displayed frame through the current look; overlay controls on top. */
export function Canvas() {
  const shoot = useApp((s) => s.shoot);
  const starting = useApp((s) => s.liveViewStarting);
  if (!shoot) return null;
  const canLive = !!shoot.identity && hasCap(shoot.identity.capabilities, Cap.liveView);
  return (
    <div className="canvas">
      {(shoot.liveViewActive || starting) && canLive ? <LiveView /> : <EditCanvas />}
      <CanvasOverlay />
    </div>
  );
}

function EditCanvas() {
  const shoot = useApp((s) => s.shoot)!;
  const item = displayedItem(shoot);
  const [shown, setShown] = useState<{ item: CaptureItem; key: string } | null>(null);
  const key = item ? `${item.id}|${shoot.look.lookId ?? "-"}|${shoot.look.strength.toFixed(2)}` : "";
  const ready = item?.state.kind === "ready";

  // Keep the last rendered frame up while the next one loads, then crossfade.
  useEffect(() => {
    if (!item) setShown(null);
  }, [item]);

  if (!item) {
    const importOnly = !!shoot.identity && !hasCap(shoot.identity.capabilities, Cap.remoteCapture);
    return (
      <div className="canvas-empty">
        {importOnly ? (
          <EmptyState icon="arrow.down.circle" title="Import only" message="Press the camera's shutter; frames show up here." />
        ) : (
          <EmptyState
            icon="camera.aperture"
            title={isLiveStatus(shoot.status) ? "Ready" : statusText(shoot.status)}
            message={isLiveStatus(shoot.status) ? (shoot.identity ? "Take a picture (Space) to see it here." : "Frames show up here as the camera sends them.") : ""}
          />
        )}
      </div>
    );
  }

  return (
    <div className="canvas-frame" onClick={() => ready && useApp.getState().openModal({ kind: "loupe", origin: "shoot" })} title={ready ? "Open the loupe (Return)" : undefined}>
      {shown && shown.key !== key ? (
        <div className="canvas-layer">
          <CaptureImage item={shown.item} variant="preview" look={shoot.look} fit="contain" lazy={false} />
        </div>
      ) : null}
      {ready ? (
        <div className="canvas-layer" key={key}>
          <CaptureImage item={item} variant="preview" look={shoot.look} fit="contain" lazy={false} onLoad={() => setShown({ item, key })} />
        </div>
      ) : item.state.kind === "downloading" ? (
        <div className="canvas-layer" style={{ filter: "blur(6px)", opacity: 0.6 }}>
          <CaptureImage item={item} variant="thumb" fit="contain" lazy={false} />
        </div>
      ) : (
        <div className="canvas-layer col" style={{ alignItems: "center", justifyContent: "center" }}><Spinner /></div>
      )}
      {item.state.kind === "downloading" ? (
        <div className="canvas-progress" aria-label={`Downloading ${item.filename}`}>
          <ProgressBar value={item.state.total ? item.state.received / item.state.total : 0.1} />
        </div>
      ) : null}
    </div>
  );
}

function LiveView() {
  const frame = useApp((s) => s.liveFrame);
  const focus = useApp((s) => s.focus);
  const shoot = useApp((s) => s.shoot)!;
  const starting = useApp((s) => s.liveViewStarting);
  const imgRef = useRef<HTMLImageElement>(null);
  const hold = useRef<{ timer: number | null; holding: boolean; point: { x: number; y: number } | null }>({ timer: null, holding: false, point: null });
  const [holding, setHolding] = useState(false);
  const canFocus = !!shoot.identity && hasCap(shoot.identity.capabilities, Cap.touchAutofocus) && isLiveStatus(shoot.status);

  /** 0…1 of the picture, or null outside it (object-fit: contain letterboxing). */
  function normalized(e: React.MouseEvent): { x: number; y: number } | null {
    const img = imgRef.current;
    if (!img || !img.naturalWidth) return null;
    const r = img.getBoundingClientRect();
    const scale = Math.min(r.width / img.naturalWidth, r.height / img.naturalHeight);
    const w = img.naturalWidth * scale;
    const h = img.naturalHeight * scale;
    const left = r.left + (r.width - w) / 2;
    const top = r.top + (r.height - h) / 2;
    const x = (e.clientX - left) / w;
    const y = (e.clientY - top) / h;
    return x >= 0 && x <= 1 && y >= 0 && y <= 1 ? { x, y } : null;
  }

  function boxStyle(): React.CSSProperties | undefined {
    const img = imgRef.current;
    if (!img || !focus.point || !img.naturalWidth) return undefined;
    const r = img.getBoundingClientRect();
    const parent = img.parentElement!.getBoundingClientRect();
    const scale = Math.min(r.width / img.naturalWidth, r.height / img.naturalHeight);
    const w = img.naturalWidth * scale;
    const h = img.naturalHeight * scale;
    return { left: r.left - parent.left + (r.width - w) / 2 + focus.point.x * w, top: r.top - parent.top + (r.height - h) / 2 + focus.point.y * h };
  }

  return (
    <div
      className="liveview"
      style={{ cursor: canFocus ? "crosshair" : "default" }}
      onMouseDown={(e) => {
        if (!canFocus || e.button !== 0) return;
        const p = normalized(e);
        if (!p) return;
        hold.current.point = p;
        hold.current.timer = window.setTimeout(() => {
          hold.current.holding = true;
          setHolding(true);
          useApp.getState().trackStart(p.x, p.y);
        }, 450);
      }}
      onMouseUp={() => {
        const h = hold.current;
        if (h.timer != null) clearTimeout(h.timer);
        h.timer = null;
        if (h.holding) {
          h.holding = false;
          setHolding(false);
          useApp.getState().trackEnd();
        } else if (h.point) {
          useApp.getState().focusAt(h.point.x, h.point.y);
        }
        h.point = null;
      }}
      aria-label="Live view from the camera"
    >
      {frame ? (
        <img ref={imgRef} src={frame.url} alt="Live view" draggable={false} />
      ) : (
        <div className="col" style={{ alignItems: "center", justifyContent: "center", height: "100%", gap: 10 }}>
          <Spinner />
          <span className="t-callout">{starting ? "Starting live view…" : "Waiting for live view…"}</span>
        </div>
      )}
      {frame && focus.point ? <FocusBox key={focus.id} indicator={focus.indicator} style={boxStyle()} /> : null}
      <div className="liveview-top">
        <TonePill text="LIVE" tone="danger" icon="circle.fill" />
        <span className="spacer" />
        {canFocus && frame ? <span className="t-caption" style={{ color: "var(--ink-1)" }}>{holding ? "Tracking, release to stop" : "Click to focus · hold to track"}</span> : null}
      </div>
    </div>
  );
}

/** The AF box: pulses while the camera works, green on focus, red on failure, then fades. */
function FocusBox({ indicator, style }: { indicator: FocusIndicator; style?: React.CSSProperties }) {
  const [gone, setGone] = useState(false);
  useEffect(() => {
    setGone(false);
    if (indicator === "focusing" || indicator === "tracking") return;
    const t = window.setTimeout(() => setGone(true), indicator === "unconfirmed" ? 400 : 900);
    return () => clearTimeout(t);
  }, [indicator]);
  const color = indicator === "focused" ? "var(--ok)" : indicator === "failed" ? "var(--danger)" : "var(--accent)";
  return (
    <span
      className={`focus-box ${indicator}`}
      style={{ ...style, borderColor: color, opacity: gone ? 0 : undefined, borderWidth: indicator === "focused" ? 3 : 2 }}
      aria-hidden
    />
  );
}

/** "Following newest / Holding this frame" and the live-view toggle, over the canvas. */
function CanvasOverlay() {
  const shoot = useApp((s) => s.shoot)!;
  const starting = useApp((s) => s.liveViewStarting);
  const stopping = useApp((s) => s.liveViewStopping);
  const on = shoot.session.showNewestCapture;
  const canLive = !!shoot.identity && hasCap(shoot.identity.capabilities, Cap.liveView);
  return (
    <div className="canvas-overlay">
      <button className={`follow-toggle glass${on ? " on" : ""}`} onClick={(e) => { e.stopPropagation(); useApp.getState().setFollowNewest(!on); }}
        aria-pressed={on} title="When on, each new frame is shown as it arrives">
        <Icon name={on ? "arrow.right.to.line" : "pin.fill"} size={13} style={{ color: on ? "var(--accent)" : "white" }} />
        {on ? "Following newest" : "Holding this frame"}
      </button>
      <span className="spacer" />
      {canLive ? (
        <button
          className={`icon-btn glass-round${shoot.liveViewActive ? " on" : ""}`}
          disabled={starting || stopping || !isLiveStatus(shoot.status)}
          onClick={(e) => { e.stopPropagation(); useApp.getState().toggleLiveView(); }}
          aria-label={starting ? "Starting live view" : shoot.liveViewActive ? "Stop live view" : "Start live view"}
          title={shoot.liveViewActive ? "Stop live view (L)" : "Start live view (L)"}
          style={shoot.liveViewActive ? { color: "var(--accent)" } : undefined}
        >
          {starting || stopping ? <Spinner small accent /> : <Icon name={shoot.liveViewActive ? "video.fill" : "video"} size={18} />}
        </button>
      ) : null}
    </div>
  );
}
