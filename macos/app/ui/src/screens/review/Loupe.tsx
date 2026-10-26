import { useEffect, useState } from "react";
import { useApp } from "../../state/store";
import type { Origin } from "../../state/types";
import { ZoomableImage, type ZoomState } from "../../components/media";
import { MetadataStrip, ReviewRow, ColorLabelPicker } from "../../components/review";
import { EmptyState, TonePill } from "../../components/common";
import { Icon } from "../../components/Icon";
import { openContextMenu, commandItems } from "../../components/Menu";
import { commandsFor, runCommand } from "../../commands/dispatcher";
import { useOrigin } from "./origin";

const FIT: ZoomState = { scale: 1, x: 0, y: 0 };

/** One frame, full window: zoom (double-click, ⌘-scroll), ← → between frames, review in the bottom bar. */
export function Loupe({ origin, onClose }: { origin: Origin; onClose: () => void }) {
  const list = useOrigin(origin);
  const [zoom, setZoom] = useState<ZoomState>(FIT);
  const [chrome, setChrome] = useState(true);
  const cur = list.current;
  useEffect(() => setZoom(FIT), [cur?.id]);
  const index = cur ? list.items.findIndex((i) => i.id === cur.id) : -1;
  const st = useApp.getState;
  const go = (d: number) => {
    const next = list.items[index + d];
    if (next) list.select(next.id);
  };

  if (!cur) {
    return (
      <div className="loupe">
        <button className="loupe-close icon-btn glass-round" onClick={onClose} aria-label="Close loupe"><Icon name="xmark" size={16} /></button>
        <EmptyState icon="photo" title="Nothing to show" message="Captures appear here once they download." />
      </div>
    );
  }
  const ids = [cur.id];
  return (
    <div className="loupe" onContextMenu={(e) => openContextMenu(e, commandItems(commandsFor(list.surface, ids), (c) => runCommand(c, ids, list.surface), ["select.", "camera.", "session."]))}>
      <ZoomableImage item={cur} look={list.look} zoom={zoom} onZoom={setZoom} onClick={() => setChrome((c) => !c)} />
      {chrome ? (
        <>
          <div className="loupe-top">
            <button className="icon-btn glass-round" onClick={onClose} aria-label="Close loupe" title="Close (Esc)"><Icon name="xmark" size={16} /></button>
            <span className="spacer" />
            {zoom.scale > 1 ? <TonePill text={`${Math.round(zoom.scale * 100)}%`} /> : null}
            <TonePill text={`${index + 1} / ${list.items.length}`} />
            {origin === "library" ? (
              <button className="icon-btn glass-round" title="Inspector" aria-label="Inspector" onClick={() => { st().setFocused(cur.id); st().setInspector(true); onClose(); }}>
                <Icon name="info.circle" size={17} />
              </button>
            ) : null}
          </div>
          {index > 0 ? (
            <button className="loupe-nav left icon-btn glass-round" aria-label="Previous frame" title="Previous (←)" onClick={() => go(-1)}><Icon name="chevron.left" size={18} /></button>
          ) : null}
          {index < list.items.length - 1 ? (
            <button className="loupe-nav right icon-btn glass-round" aria-label="Next frame" title="Next (→)" onClick={() => go(1)}><Icon name="chevron.right" size={18} /></button>
          ) : null}
          <div className="loupe-bottom">
            <MetadataStrip item={cur} />
            <div className="row" style={{ padding: "0 16px 12px", gap: 24, justifyContent: "center" }}>
              <div style={{ width: 360 }}>
                <ReviewRow item={cur} size={24} onRate={(n) => st().rate(ids, n)} onFlag={(f) => st().flag(ids, f)} />
              </div>
              <ColorLabelPicker current={cur.colorLabel} onPick={(l) => st().label(ids, l)} />
            </div>
          </div>
        </>
      ) : null}
    </div>
  );
}
