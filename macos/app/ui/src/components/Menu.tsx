import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { create } from "zustand";
import { Icon } from "./Icon";
import { Kbd } from "./common";
import { sections, type Command } from "../commands/catalogue";

export type MenuItem =
  | { kind?: "item"; title: string; icon?: string; iconColor?: string; shortcut?: string; destructive?: boolean; disabled?: boolean; checked?: boolean; onSelect: () => void }
  | { kind: "divider" }
  | { kind: "header"; title: string }
  | { kind: "submenu"; title: string; icon?: string; items: MenuItem[] }
  | { kind: "custom"; render: (close: () => void) => ReactNode };

interface MenuState {
  open: { items: MenuItem[]; x: number; y: number; minWidth?: number; anchorBottom?: number; owner?: string; alignRight?: boolean } | null;
  show(items: MenuItem[], x: number, y: number, opts?: { minWidth?: number; anchorBottom?: number; owner?: string; alignRight?: boolean }): void;
  close(): void;
}

export const useMenu = create<MenuState>()((set) => ({
  open: null,
  show(items, x, y, opts) {
    set({ open: { items, x, y, ...opts } });
  },
  close() {
    set({ open: null });
  },
}));

/** Opens `items` at the mouse (right click). */
export function openContextMenu(e: React.MouseEvent, items: MenuItem[]) {
  e.preventDefault();
  e.stopPropagation();
  if (items.length) useMenu.getState().show(items, e.clientX, e.clientY);
}

/** Menu items from commands, grouped with dividers (CommandMenuContent on iOS). */
export function commandItems(commands: Command[], run: (c: Command) => void, exclude: string[] = []): MenuItem[] {
  const out: MenuItem[] = [];
  const filtered = commands.filter((c) => !exclude.some((p) => c.id.startsWith(p)));
  const item = (c: Command): MenuItem => {
    const label = c.id.startsWith("label.") && c.id !== "label.none" ? c.id.slice(6) : null;
    return {
      title: c.title, icon: c.symbol, shortcut: c.shortcut, destructive: c.isDestructive,
      iconColor: label ? `var(--label-${label})` : undefined, onSelect: () => run(c),
    };
  };
  sections(filtered).forEach((s, i) => {
    if (i > 0) out.push({ kind: "divider" });
    // Ratings and colour labels fold into submenus so context menus stay short.
    const rates = s.commands.filter((c) => c.id.startsWith("rate."));
    const labels = s.commands.filter((c) => c.id.startsWith("label."));
    if (rates.length > 1) out.push({ kind: "submenu", title: "Rating", icon: "star", items: rates.map(item) });
    if (labels.length > 1) out.push({ kind: "submenu", title: "Colour label", icon: "circle.lefthalf.filled", items: labels.map(item) });
    for (const c of s.commands) {
      if ((rates.length > 1 && c.id.startsWith("rate.")) || (labels.length > 1 && c.id.startsWith("label."))) continue;
      out.push(item(c));
    }
  });
  return out;
}

/** A button that opens a dropdown menu below itself. */
export function MenuButton({
  items, children, className, label, title, align = "left", minWidth, disabled, style,
}: { items: MenuItem[] | (() => MenuItem[]); children: ReactNode; className?: string; label?: string; title?: string; align?: "left" | "right"; minWidth?: number; disabled?: boolean; style?: React.CSSProperties }) {
  const ref = useRef<HTMLButtonElement>(null);
  const owner = useRef(`m${Math.random()}`).current;
  const isOpen = useMenu((s) => s.open?.owner === owner);
  return (
    <button
      ref={ref}
      type="button"
      className={className ?? "icon-btn"}
      aria-label={label}
      aria-haspopup="menu"
      aria-expanded={isOpen}
      title={title}
      disabled={disabled}
      style={style}
      onMouseDown={(e) => e.preventDefault()}
      onClick={() => {
        if (isOpen) return useMenu.getState().close();
        const r = ref.current?.getBoundingClientRect();
        if (!r) return;
        const list = typeof items === "function" ? items() : items;
        useMenu.getState().show(list, align === "right" ? r.right : r.left, r.bottom + 4, { minWidth: minWidth ?? Math.max(180, r.width), anchorBottom: r.top, owner, alignRight: align === "right" });
      }}
    >
      {children}
    </button>
  );
}

function MenuList({ items, x, y, minWidth, anchorBottom, onClose, depth = 0, alignRight }: {
  items: MenuItem[]; x: number; y: number; minWidth?: number; anchorBottom?: number; onClose: () => void; depth?: number; alignRight?: boolean;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState({ left: x, top: y, ready: false });
  const [active, setActive] = useState(-1);
  const [sub, setSub] = useState<{ index: number; x: number; y: number } | null>(null);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    let left = alignRight ? x - r.width : x;
    let top = y;
    if (left < 8) left = 8;
    if (left + r.width > window.innerWidth - 8) left = Math.max(8, (depth > 0 ? x - r.width - 200 : window.innerWidth - r.width - 8));
    if (top + r.height > window.innerHeight - 8) {
      top = anchorBottom != null && anchorBottom - r.height - 4 > 8 ? anchorBottom - r.height - 4 : Math.max(8, window.innerHeight - r.height - 8);
    }
    setPos({ left, top, ready: true });
  }, [x, y, anchorBottom, depth, items, alignRight]);

  const selectable = items.map((it, i) => ((it.kind === undefined || it.kind === "item") && !(it as { disabled?: boolean }).disabled ? i : -1)).filter((i) => i >= 0);

  useEffect(() => {
    if (depth > 0) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        e.stopPropagation();
        const cur = selectable.indexOf(active);
        const next = e.key === "ArrowDown" ? selectable[(cur + 1) % selectable.length] : selectable[(cur - 1 + selectable.length) % selectable.length];
        setActive(next ?? -1);
      } else if (e.key === "Enter" && active >= 0) {
        e.preventDefault();
        e.stopPropagation();
        const it = items[active];
        if (it && (it.kind === undefined || it.kind === "item")) {
          onClose();
          it.onSelect();
        }
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  });

  return (
    <div
      ref={ref}
      className="menu glass"
      role="menu"
      style={{ left: pos.left, top: pos.top, minWidth: minWidth ?? 200, visibility: pos.ready ? "visible" : "hidden" }}
      onMouseDown={(e) => e.stopPropagation()}
      onContextMenu={(e) => e.preventDefault()}
    >
      {items.map((it, i) => {
        if (it.kind === "divider") return i === 0 || i === items.length - 1 ? null : <div key={i} className="menu-divider" />;
        if (it.kind === "header") return <div key={i} className="menu-header">{it.title}</div>;
        if (it.kind === "custom") return <div key={i} className="menu-custom">{it.render(onClose)}</div>;
        if (it.kind === "submenu") {
          return (
            <div
              key={i}
              className={`menu-item${sub?.index === i ? " active" : ""}`}
              role="menuitem"
              aria-haspopup="menu"
              onMouseEnter={(e) => {
                const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
                setActive(i);
                setSub({ index: i, x: r.right + 2, y: r.top - 5 });
              }}
            >
              <span className="menu-icon">{it.icon ? <Icon name={it.icon} size={14} /> : null}</span>
              <span className="fill truncate">{it.title}</span>
              <Icon name="chevron.right" size={11} />
              {sub?.index === i
                ? createPortal(<MenuList items={it.items} x={sub.x} y={sub.y} onClose={onClose} depth={depth + 1} />, document.body)
                : null}
            </div>
          );
        }
        return (
          <button
            key={i}
            type="button"
            role="menuitem"
            className={`menu-item${active === i ? " active" : ""}${it.destructive ? " destructive" : ""}`}
            disabled={it.disabled}
            onMouseEnter={() => {
              setActive(i);
              setSub(null);
            }}
            onClick={() => {
              onClose();
              it.onSelect();
            }}
          >
            <span className="menu-icon">
              {it.checked ? <Icon name="checkmark" size={13} strokeWidth={2.4} /> : it.icon ? <Icon name={it.icon} size={14} style={it.iconColor ? { color: it.iconColor } : undefined} /> : null}
            </span>
            <span className="fill truncate">{it.title}</span>
            {it.shortcut ? <Kbd>{it.shortcut}</Kbd> : null}
          </button>
        );
      })}
    </div>
  );
}

/** Renders the one open menu; closes on outside click, scroll, blur or Esc (handled by the key router). */
export function MenuHost() {
  const open = useMenu((s) => s.open);
  const close = useMenu((s) => s.close);
  useEffect(() => {
    if (!open) return;
    const down = () => close();
    const blur = () => close();
    window.addEventListener("mousedown", down);
    window.addEventListener("blur", blur);
    window.addEventListener("resize", blur);
    return () => {
      window.removeEventListener("mousedown", down);
      window.removeEventListener("blur", blur);
      window.removeEventListener("resize", blur);
    };
  }, [open, close]);
  if (!open) return null;
  return createPortal(
    <MenuList items={open.items} x={open.x} y={open.y} minWidth={open.minWidth} anchorBottom={open.anchorBottom} alignRight={open.alignRight} onClose={close} />,
    document.body,
  );
}
