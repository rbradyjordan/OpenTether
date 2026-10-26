import { useState } from "react";
import type { CaptureItem } from "../../api";
import type { Origin } from "../../state/types";
import { ZoomableImage, CaptureImage, type ZoomState } from "../../components/media";
import { MetadataStrip, ReviewRow } from "../../components/review";
import { Icon } from "../../components/Icon";
import { useApp } from "../../state/store";
import { useOrigin } from "./origin";

/** Two-up with synced zoom; "Change" on a side picks its frame from a strip. */
export function Compare({ origin, ids, onClose }: { origin: Origin; ids: string[]; onClose: () => void }) {
  const list = useOrigin(origin);
  const [left, setLeft] = useState<string | null>(ids[0] ?? list.current?.id ?? list.items.at(-1)?.id ?? null);
  const [right, setRight] = useState<string | null>(ids[1] ?? list.items.filter((i) => i.id !== left).at(-1)?.id ?? null);
  const [zoom, setZoom] = useState<ZoomState>({ scale: 1, x: 0, y: 0 });
  const [picking, setPicking] = useState<"left" | "right" | null>(null);
  const find = (id: string | null) => list.items.find((i) => i.id === id) ?? null;

  return (
    <div className="compare">
      <div className="toolbar">
        <span className="title">Compare</span>
        <span className="t-hud ink-2">Zoom is synced · double-click for 100 %</span>
        <span className="spacer" />
        <button className="btn secondary small" onClick={() => { setLeft(right); setRight(left); }}>
          <Icon name="arrow.left.arrow.right" size={13} /> Swap
        </button>
        <button className="btn primary small" onClick={onClose}>Done</button>
      </div>
      <div className="compare-panes">
        <Pane item={find(left)} look={list.look} zoom={zoom} onZoom={setZoom} onChange={() => setPicking("left")} />
        <Pane item={find(right)} look={list.look} zoom={zoom} onZoom={setZoom} onChange={() => setPicking("right")} />
      </div>
      {picking ? (
        <div className="compare-picker glass">
          <div className="row" style={{ padding: "8px 12px" }}>
            <span className="t-headline">{picking === "left" ? "Left image" : "Right image"}</span>
            <span className="spacer" />
            <button className="icon-btn round" aria-label="Close picker" onClick={() => setPicking(null)}><Icon name="xmark" size={14} /></button>
          </div>
          <div className="compare-strip">
            {list.items.map((i) => (
              <button key={i.id} className="compare-thumb" aria-label={i.filename}
                onClick={() => { if (picking === "left") setLeft(i.id); else setRight(i.id); setPicking(null); }}>
                <CaptureImage item={i} variant="thumb" />
              </button>
            ))}
          </div>
        </div>
      ) : null}
    </div>
  );
}

function Pane({ item, look, zoom, onZoom, onChange }: { item: CaptureItem | null; look: import("../../api").LookStack | null; zoom: ZoomState; onZoom: (z: ZoomState) => void; onChange: () => void }) {
  return (
    <div className="compare-pane">
      <ZoomableImage item={item} look={look} zoom={zoom} onZoom={onZoom} />
      {item ? (
        <div className="compare-meta">
          <div className="row">
            <div className="fill"><MetadataStrip item={item} /></div>
            <button className="btn secondary small" style={{ marginRight: 10 }} onClick={onChange}>Change</button>
          </div>
          <div style={{ padding: "0 16px 10px" }}>
            <ReviewRow item={item} size={20} onRate={(n) => useApp.getState().rate([item.id], n)} onFlag={(f) => useApp.getState().flag([item.id], f)} />
          </div>
        </div>
      ) : (
        <button className="btn secondary compare-empty" onClick={onChange}>Pick a frame</button>
      )}
    </div>
  );
}
