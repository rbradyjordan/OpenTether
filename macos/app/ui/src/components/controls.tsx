import type { CSSProperties, ReactNode } from "react";
import { Icon } from "./Icon";

export function Toggle({ on, onChange, disabled, label }: { on: boolean; onChange: (v: boolean) => void; disabled?: boolean; label?: string }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      aria-label={label}
      className={`toggle${on ? " on" : ""}`}
      disabled={disabled}
      onClick={() => onChange(!on)}
    />
  );
}

export interface Option<T extends string | number> {
  value: T;
  label: string;
  disabled?: boolean;
}

export function Select<T extends string | number>({
  value, options, onChange, disabled, label, style,
}: { value: T; options: Option<T>[]; onChange: (v: T) => void; disabled?: boolean; label?: string; style?: CSSProperties }) {
  return (
    <span className="select-wrap" style={style}>
      <select
        className="field"
        aria-label={label}
        value={String(value)}
        disabled={disabled}
        onChange={(e) => {
          const o = options.find((x) => String(x.value) === e.target.value);
          if (o) onChange(o.value);
        }}
      >
        {options.map((o) => (
          <option key={String(o.value)} value={String(o.value)} disabled={o.disabled}>
            {o.label}
          </option>
        ))}
      </select>
      <Icon name="chevron.up.chevron.down" size={13} />
    </span>
  );
}

export function Slider({
  value, min, max, step, onChange, label,
}: { value: number; min: number; max: number; step?: number; onChange: (v: number) => void; label?: string }) {
  const pct = ((value - min) / (max - min)) * 100;
  return (
    <input
      type="range"
      className="slider"
      aria-label={label}
      min={min}
      max={max}
      step={step ?? "any"}
      value={value}
      style={{ ["--pct" as string]: `${pct}%` }}
      onChange={(e) => onChange(Number(e.target.value))}
    />
  );
}

export function Segmented<T extends string>({ value, options, onChange }: { value: T; options: Option<T>[]; onChange: (v: T) => void }) {
  return (
    <div className="segmented" role="radiogroup">
      {options.map((o) => (
        <button key={o.value} type="button" role="radio" aria-checked={o.value === value} className={o.value === value ? "on" : ""} onClick={() => onChange(o.value)}>
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function TextField({
  value, onChange, placeholder, mono, autoFocus, onSubmit, label, type, style, disabled, onKeyDown,
}: {
  value: string; onChange: (v: string) => void; placeholder?: string; mono?: boolean; autoFocus?: boolean; onSubmit?: () => void; label?: string;
  type?: string; style?: CSSProperties; disabled?: boolean; onKeyDown?: (e: React.KeyboardEvent<HTMLInputElement>) => void;
}) {
  return (
    <input
      className={`field${mono ? " mono" : ""}`}
      value={value}
      type={type ?? "text"}
      placeholder={placeholder}
      aria-label={label ?? placeholder}
      autoFocus={autoFocus}
      spellCheck={false}
      autoComplete="off"
      autoCorrect="off"
      autoCapitalize="off"
      disabled={disabled}
      style={style}
      onChange={(e) => onChange(e.target.value)}
      onKeyDown={(e) => {
        onKeyDown?.(e);
        if (e.key === "Enter" && onSubmit) {
          e.preventDefault();
          onSubmit();
        }
      }}
    />
  );
}

/** A caption above a field, so a filled-in value still says what it is. */
export function Labeled({ label, children, style }: { label: string; children: ReactNode; style?: CSSProperties }) {
  return (
    <label className="labeled" style={style}>
      <span className="t-caption">{label}</span>
      {children}
    </label>
  );
}

export function FormSection({ title, footer, children }: { title?: string; footer?: ReactNode; children: ReactNode }) {
  return (
    <section className="form-section">
      {title ? <div className="t-caption">{title}</div> : null}
      <div className="form-group">{children}</div>
      {footer ? <div className="form-footer">{footer}</div> : null}
    </section>
  );
}

export function FormRow({ label, children, hint }: { label: ReactNode; children?: ReactNode; hint?: ReactNode }) {
  return (
    <div className="form-row">
      <div className="form-label">
        <div>{label}</div>
        {hint ? <div className="t-hud ink-2">{hint}</div> : null}
      </div>
      {children}
    </div>
  );
}
