import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { api, type CaptureItem, type ImageVariant, type LookStack } from "../api";
import { Icon } from "./Icon";
import { Spinner } from "./common";

/** A capture rendition with a fade-in; `fit` contain for canvases, cover for tiles. */
export function CaptureImage({
  item, variant = "thumb", look, fit = "cover", style, className, alt, onLoad, lazy = true,
}: { item: Pick<CaptureItem, "id" | "revision" | "filename">; variant?: ImageVariant; look?: LookStack | null; fit?: "cover" | "contain"; style?: CSSProperties; className?: string; alt?: string; onLoad?: (img: HTMLImageElement) => void; lazy?: boolean }) {
  const [loaded, setLoaded] = useState(false);
  const src = api.imageUrl(item, variant, { look: look ?? null, revision: item.revision });
  return (
    <img
      src={src}
      alt={alt ?? item.filename}
      draggable={false}
      loading={lazy ? "lazy" : "eager"}
      decoding="async"
      className={className}
      onLoad={(e) => {
        setLoaded(true);
        onLoad?.(e.currentTarget);
      }}
      style={{ width: "100%", height: "100%", objectFit: fit, opacity: loaded ? 1 : 0, transition: "opacity 220ms ease-out", ...style }}
    />
  );
}

/**
 * Zoomable, pannable frame for loupes and compare. Double click or Z toggles
 * fit ↔ 100 %; wheel / pinch zooms around the pointer. `zoom` and `offset` can be
 * shared between panes (synced compare).
 */
export interface ZoomState {
  scale: number;
  x: number;
  y: number;
}

export function ZoomableImage({
  item, look, zoom, onZoom, children, onClick,
}: { item: CaptureItem | null; look?: LookStack | null; zoom: ZoomState; onZoom: (z: ZoomState) => void; children?: ReactNode; onClick?: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  const drag = useRef<{ x: number; y: number; ox: number; oy: number; moved: boolean } | null>(null);
  const [natural, setNatural] = useState<{ w: number; h: number } | null>(null);
  useEffect(() => setNatural(null), [item?.id]);

  function fitScale(): number {
    const el = ref.current;
    if (!el || !natural) return 1;
    return Math.min(el.clientWidth / natural.w, el.clientHeight / natural.h);
  }

  function zoomAround(next: number, cx: number, cy: number) {
    const s = Math.max(1, Math.min(8, next));
    const el = ref.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    const px = cx - r.left - r.width / 2;
    const py = cy - r.top - r.height / 2;
    const k = s / zoom.scale;
    onZoom({ scale: s, x: s === 1 ? 0 : px - (px - zoom.x) * k, y: s === 1 ? 0 : py - (py - zoom.y) * k });
  }

  if (!item) {
    return <div className="zoomable" ref={ref} />;
  }
  return (
    <div
      className="zoomable"
      ref={ref}
      onWheel={(e) => {
        if (!e.ctrlKey && !e.metaKey && zoom.scale === 1) return;
        e.preventDefault();
        if (e.ctrlKey || e.metaKey) zoomAround(zoom.scale * Math.exp(-e.deltaY * 0.01), e.clientX, e.clientY);
        else onZoom({ ...zoom, x: zoom.x - e.deltaX, y: zoom.y - e.deltaY });
      }}
      onDoubleClick={(e) => {
        const actual = natural ? 1 / fitScale() : 2.5;
        zoomAround(zoom.scale > 1 ? 1 : Math.max(2, actual), e.clientX, e.clientY);
      }}
      onMouseDown={(e) => {
        if (e.button !== 0) return;
        drag.current = { x: e.clientX, y: e.clientY, ox: zoom.x, oy: zoom.y, moved: false };
      }}
      onMouseMove={(e) => {
        const d = drag.current;
        if (!d) return;
        if (Math.abs(e.clientX - d.x) + Math.abs(e.clientY - d.y) > 3) d.moved = true;
        if (zoom.scale > 1 && d.moved) onZoom({ ...zoom, x: d.ox + e.clientX - d.x, y: d.oy + e.clientY - d.y });
      }}
      onMouseUp={() => {
        const d = drag.current;
        drag.current = null;
        if (d && !d.moved) onClick?.();
      }}
      onMouseLeave={() => (drag.current = null)}
      style={{ cursor: zoom.scale > 1 ? "grab" : "zoom-in" }}
    >
      <div style={{ position: "absolute", inset: 0, transform: `translate(${zoom.x}px, ${zoom.y}px) scale(${zoom.scale})`, transformOrigin: "center", transition: drag.current ? "none" : "transform 160ms ease-out" }}>
        <CaptureImage
          key={item.id}
          item={item}
          variant="preview"
          look={look}
          fit="contain"
          lazy={false}
          onLoad={(img) => setNatural({ w: img.naturalWidth, h: img.naturalHeight })}
        />
      </div>
      {children}
    </div>
  );
}

export function ImagePlaceholder({ label, busy }: { label?: string; busy?: boolean }) {
  return (
    <div className="col" style={{ alignItems: "center", justifyContent: "center", height: "100%", color: "var(--ink-1)", gap: 10 }}>
      {busy ? <Spinner /> : <Icon name="photo" size={28} />}
      {label ? <span className="t-callout">{label}</span> : null}
    </div>
  );
}
