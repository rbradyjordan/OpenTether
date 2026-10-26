import type { CSSProperties, ReactNode } from "react";
import { Icon } from "./Icon";

/** A modal sheet: title bar, scrolling body, action footer. Closed by Esc (key router) or the × button. */
export function Sheet({
  title, onClose, children, footer, width = 560, height, headerTrailing, bodyStyle, bodyClassName, subtitle,
}: {
  title: string; onClose: () => void; children: ReactNode; footer?: ReactNode; width?: number; height?: number | string;
  headerTrailing?: ReactNode; bodyStyle?: CSSProperties; bodyClassName?: string; subtitle?: string;
}) {
  return (
    <div className="sheet" role="dialog" aria-modal="true" aria-label={title} style={{ width, height }} onMouseDown={(e) => e.stopPropagation()}>
      <header className="sheet-header">
        <div className="col" style={{ gap: 0, minWidth: 0 }}>
          <span className="t-headline truncate">{title}</span>
          {subtitle ? <span className="t-hud ink-2 truncate">{subtitle}</span> : null}
        </div>
        <span className="spacer" />
        {headerTrailing}
        <button className="icon-btn round" onClick={onClose} aria-label="Close" title="Close (Esc)">
          <Icon name="xmark" size={14} strokeWidth={2.2} />
        </button>
      </header>
      <div className={`sheet-body ${bodyClassName ?? ""}`} style={bodyStyle}>
        {children}
      </div>
      {footer ? <footer className="sheet-footer">{footer}</footer> : null}
    </div>
  );
}

/** Two-button footer: secondary on the left of primary, both right-aligned (macOS). */
export function SheetActions({
  onCancel, cancelTitle = "Cancel", primaryTitle, onPrimary, primaryDisabled, destructive, leading,
}: { onCancel?: () => void; cancelTitle?: string; primaryTitle?: string; onPrimary?: () => void; primaryDisabled?: boolean; destructive?: boolean; leading?: ReactNode }) {
  return (
    <>
      {leading}
      <span className="spacer" />
      {onCancel ? <button className="btn secondary quiet" onClick={onCancel}>{cancelTitle}</button> : null}
      {primaryTitle && onPrimary ? (
        <button className={`btn primary${destructive ? " danger" : ""}`} disabled={primaryDisabled} onClick={onPrimary}>
          {primaryTitle}
        </button>
      ) : null}
    </>
  );
}
