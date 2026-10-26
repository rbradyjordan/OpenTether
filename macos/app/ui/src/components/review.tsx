import { useState } from "react";
import { COLOR_LABELS, exposureLine, type CaptureFlag, type CaptureItem, type ColorLabel } from "../api";
import { Icon } from "./Icon";

export const labelColor = (l: ColorLabel) => (l === "none" ? "transparent" : `var(--label-${l})`);

/** Five stars; clicking the current rating clears it. Hover previews. */
export function RatingStars({ rating, size = 22, onRate }: { rating: number; size?: number; onRate: (n: number) => void }) {
  const [hover, setHover] = useState<number | null>(null);
  const shown = hover ?? rating;
  return (
    <div className="row" style={{ gap: 2 }} role="slider" aria-label="Rating" aria-valuemin={0} aria-valuemax={5} aria-valuenow={rating}
      onMouseLeave={() => setHover(null)}>
      {[1, 2, 3, 4, 5].map((star) => (
        <button
          key={star}
          type="button"
          aria-label={`${star} star${star === 1 ? "" : "s"}`}
          onMouseEnter={() => setHover(star)}
          onClick={() => onRate(star === rating ? 0 : star)}
          style={{ display: "inline-flex", padding: 3, color: star <= shown ? "var(--pick)" : "var(--ink-2)", transition: "transform 150ms var(--ease-snap)", transform: hover === star ? "scale(1.12)" : undefined }}
        >
          <Icon name={star <= shown ? "star.fill" : "star"} size={size} strokeWidth={1.6} />
        </button>
      ))}
    </div>
  );
}

export function RatingDots({ rating }: { rating: number }) {
  if (rating <= 0) return null;
  return (
    <span style={{ display: "inline-flex", gap: 2, padding: "2px 3px", borderRadius: 4, background: "rgba(0,0,0,0.45)" }} aria-label={`${rating} stars`}>
      {Array.from({ length: rating }, (_, i) => (
        <span key={i} style={{ width: 4, height: 4, borderRadius: 2, background: "var(--pick)" }} />
      ))}
    </span>
  );
}

/** Pick or Reject; clicking the active one clears the flag. */
export function FlagButton({ kind, flag, onFlag, size = 20 }: { kind: "pick" | "reject"; flag: CaptureFlag; onFlag: (f: CaptureFlag) => void; size?: number }) {
  const on = flag === kind;
  const tint = kind === "pick" ? "var(--ok)" : "var(--danger)";
  const icon = kind === "pick" ? (on ? "flag.fill" : "flag") : on ? "xmark.circle.fill" : "xmark.circle";
  return (
    <button
      type="button"
      className="icon-btn round"
      aria-label={kind === "pick" ? "Pick" : "Reject"}
      aria-pressed={on}
      title={kind === "pick" ? "Pick (P)" : "Reject (X)"}
      onClick={() => onFlag(on ? "none" : kind)}
      style={{ width: size + 18, height: size + 18, color: on ? tint : "var(--ink-1)", background: on ? (kind === "pick" ? "rgba(61,214,140,0.16)" : "rgba(255,92,92,0.16)") : undefined }}
    >
      <Icon name={icon} size={size} />
    </button>
  );
}

export function ColorLabelPicker({ current, onPick }: { current: ColorLabel; onPick: (l: ColorLabel) => void }) {
  return (
    <div className="row" style={{ gap: 6 }} role="radiogroup" aria-label="Colour label">
      {COLOR_LABELS.map((l) => (
        <button
          key={l}
          type="button"
          role="radio"
          aria-checked={current === l}
          aria-label={`${l} label`}
          title={l[0].toUpperCase() + l.slice(1)}
          onClick={() => onPick(current === l ? "none" : l)}
          style={{
            width: 22, height: 22, borderRadius: 11, background: labelColor(l),
            boxSizing: "border-box", border: current === l ? "2px solid var(--ink-0)" : "2px solid transparent",
            outline: current === l ? "1px solid var(--surface-1)" : undefined, outlineOffset: -4,
          }}
        />
      ))}
      <button type="button" className="icon-btn" style={{ width: 24, height: 24 }} aria-label="Clear label" title="No label" onClick={() => onPick("none")}>
        <Icon name="circle" size={16} />
      </button>
    </div>
  );
}

/** Corner badges on grid tiles and filmstrip cells. */
export function TileBadges({ item, pairCount, compact }: { item: CaptureItem; pairCount: number; compact?: boolean }) {
  return (
    <div style={{ position: "absolute", inset: 0, padding: compact ? 3 : 5, display: "flex", flexDirection: "column", pointerEvents: "none" }}>
      <div className="row" style={{ gap: 3 }}>
        {item.flag === "pick" ? <Icon name="flag.fill" size={11} style={{ color: "var(--ok)", filter: "drop-shadow(0 0 1px rgba(0,0,0,.8))" }} /> : null}
        {item.flag === "reject" ? <Icon name="xmark.circle.fill" size={11} style={{ color: "var(--danger)" }} /> : null}
        {item.colorLabel !== "none" ? <span style={{ width: 8, height: 8, borderRadius: 4, background: labelColor(item.colorLabel), boxShadow: "0 0 0 1px rgba(0,0,0,.4)" }} /> : null}
        <span className="spacer" />
        {pairCount > 1 || item.kind === "raw" ? <span className="badge-mini">{pairCount > 1 ? "R+J" : "RAW"}</span> : null}
      </div>
      <span className="spacer" />
      <div className="row">
        <RatingDots rating={item.rating} />
        <span className="spacer" />
        {item.lookId && !compact ? <Icon name="camera.filters" size={11} style={{ color: "white", filter: "drop-shadow(0 0 1px rgba(0,0,0,.8))" }} /> : null}
      </div>
    </div>
  );
}

export function MetadataStrip({ item, position }: { item: CaptureItem; position?: string }) {
  const line = exposureLine(item.exposure);
  return (
    <div className="row t-hud" style={{ gap: 12, padding: "6px 16px" }}>
      <span className="ink-0 truncate">{item.filename}</span>
      <span className="ink-2">{item.width}×{item.height}</span>
      {line ? <span className="ink-1 truncate">{line}</span> : null}
      <span className="spacer" />
      {position ? <span className="ink-1">{position}</span> : null}
    </div>
  );
}

/** Stars between Reject and Pick: the review row in the shoot bar, loupes and the inspector. */
export function ReviewRow({ item, onRate, onFlag, size = 22 }: { item: CaptureItem; onRate: (n: number) => void; onFlag: (f: CaptureFlag) => void; size?: number }) {
  return (
    <div className="row" style={{ justifyContent: "space-between", gap: 12 }}>
      <FlagButton kind="reject" flag={item.flag} onFlag={onFlag} />
      <RatingStars rating={item.rating} size={size} onRate={onRate} />
      <FlagButton kind="pick" flag={item.flag} onFlag={onFlag} />
    </div>
  );
}
