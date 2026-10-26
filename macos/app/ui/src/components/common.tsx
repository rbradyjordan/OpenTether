import type { CSSProperties, ReactNode } from "react";
import { Icon } from "./Icon";

export function IconTile({ name, active, size = 36 }: { name: string; active?: boolean; size?: number }) {
  return (
    <span className={`icon-tile${active ? " active" : ""}`} style={{ width: size, height: size, borderRadius: size * 0.28 }}>
      <Icon name={name} size={Math.round(size * 0.5)} strokeWidth={2} />
    </span>
  );
}

export function SectionCard({
  title, icon, children, trailing, style, className,
}: { title?: string | null; icon?: string; children: ReactNode; trailing?: ReactNode; style?: CSSProperties; className?: string }) {
  return (
    <section className={`card section-card ${className ?? ""}`} style={style}>
      {title ? (
        <header>
          {icon ? <Icon name={icon} size={14} /> : null}
          <span className="t-caption">{title}</span>
          <span className="spacer" />
          {trailing}
        </header>
      ) : null}
      {children}
    </section>
  );
}

export function EmptyState({
  icon, title, message, action, onAction,
}: { icon: string; title: string; message?: string; action?: string; onAction?: () => void }) {
  return (
    <div className="empty-state">
      <Icon name={icon} size={40} strokeWidth={1.4} />
      <div className="t-title">{title}</div>
      {message ? <div className="t-callout">{message}</div> : null}
      {action && onAction ? (
        <button className="btn secondary" style={{ marginTop: 8 }} onClick={onAction}>
          {action}
        </button>
      ) : null}
    </div>
  );
}

export function ActionCard({
  title, subtitle, icon, badge, live, onClick, trailing,
}: { title: string; subtitle?: string; icon: string; badge?: string | null; live?: boolean; onClick?: () => void; trailing?: ReactNode }) {
  return (
    <button className="action-card" onClick={onClick}>
      <IconTile name={icon} active={live} size={40} />
      <span className="col fill" style={{ gap: 2 }}>
        <span className="row">
          <span className="t-headline">{title}</span>
          {badge ? <TonePill tone="ok" text={badge} icon="circle.fill" /> : null}
        </span>
        {subtitle ? <span className="t-callout">{subtitle}</span> : null}
      </span>
      {trailing ?? <Icon name="chevron.right" size={14} className="ink-2" />}
    </button>
  );
}

export type Tone = "neutral" | "ok" | "warn" | "danger" | "accent";

export function TonePill({ text, tone = "neutral", icon }: { text: string; tone?: Tone; icon?: string }) {
  return (
    <span className={`pill ${tone}`}>
      {icon ? <Icon name={icon} size={icon === "circle.fill" ? 7 : 11} /> : null}
      {text}
    </span>
  );
}

export function Spinner({ small, accent }: { small?: boolean; accent?: boolean }) {
  return <span className={`spinner${small ? " small" : ""}${accent ? " accent" : ""}`} role="progressbar" aria-label="Working" />;
}

/** Download ring: determinate when progress is known, else spinning. Flashes ok on completion. */
export function ProgressRing({ progress, size = 26, done }: { progress: number | null; size?: number; done?: boolean }) {
  const r = (size - 4) / 2;
  const c = 2 * Math.PI * r;
  if (done) {
    return (
      <span style={{ color: "var(--ok)", display: "inline-flex" }}>
        <Icon name="checkmark.circle.fill" size={size} />
      </span>
    );
  }
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} style={progress == null ? { animation: "spin 1s linear infinite" } : undefined} aria-label="Downloading">
      <circle cx={size / 2} cy={size / 2} r={r} stroke="rgba(255,255,255,0.25)" strokeWidth="2.5" fill="rgba(0,0,0,0.35)" />
      <circle
        cx={size / 2}
        cy={size / 2}
        r={r}
        stroke="var(--accent)"
        strokeWidth="2.5"
        fill="none"
        strokeLinecap="round"
        strokeDasharray={c}
        strokeDashoffset={progress == null ? c * 0.7 : c * (1 - Math.max(0.03, progress))}
        transform={`rotate(-90 ${size / 2} ${size / 2})`}
        style={{ transition: "stroke-dashoffset 250ms ease-out" }}
      />
    </svg>
  );
}

export function Kbd({ children }: { children: ReactNode }) {
  return <span className="kbd">{children}</span>;
}

export function ProgressBar({ value, tone = "accent" }: { value: number; tone?: "accent" | "ok" | "danger" }) {
  const color = tone === "ok" ? "var(--ok)" : tone === "danger" ? "var(--danger)" : "var(--accent)";
  return (
    <div style={{ height: 4, borderRadius: 2, background: "rgba(255,255,255,0.12)", overflow: "hidden" }}>
      <div style={{ height: "100%", width: `${Math.max(0, Math.min(1, value)) * 100}%`, background: color, borderRadius: 2, transition: "width 220ms ease-out" }} />
    </div>
  );
}

/** Back-button header for a pushed screen in a stack. */
export function ScreenHeader({ title, onBack, backTitle, trailing }: { title: string; onBack?: () => void; backTitle?: string; trailing?: ReactNode }) {
  return (
    <div className="toolbar">
      {onBack ? (
        <button className="btn plain" style={{ paddingLeft: 2, gap: 2 }} onClick={onBack} aria-label={`Back to ${backTitle ?? "previous"}`}>
          <Icon name="chevron.left" size={16} strokeWidth={2.2} />
          {backTitle ?? "Back"}
        </button>
      ) : null}
      <span className="title truncate">{title}</span>
      <span className="spacer" />
      {trailing}
    </div>
  );
}
