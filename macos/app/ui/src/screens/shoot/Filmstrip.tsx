import { useEffect, useRef } from "react";
import { downloadProgress, isFailed, isReady, type CaptureItem } from "../../api";
import { useApp, displayedItem } from "../../state/store";
import { CaptureImage } from "../../components/media";
import { TileBadges } from "../../components/review";
import { ProgressRing } from "../../components/common";
import { Icon } from "../../components/Icon";
import { openContextMenu, commandItems } from "../../components/Menu";
import { commandsFor, runCommand } from "../../commands/dispatcher";

/**
 * Captures as a row under the photo, or a column beside it in the wide
 * layout. New frames slide in at the trailing end with a download ring;
 * with "Holding this frame" a count badge increments instead.
 */
export function Filmstrip({ vertical }: { vertical?: boolean }) {
  const shoot = useApp((s) => s.shoot);
  const unseen = useApp((s) => s.unseen);
  const ref = useRef<HTMLDivElement>(null);
  const shown = displayedItem(shoot);
  const items = shoot?.items ?? [];
  const count = items.length;

  useEffect(() => {
    if (!shown) return;
    ref.current?.querySelector<HTMLElement>(`[data-id="${shown.id}"]`)?.scrollIntoView({ block: "nearest", inline: "nearest", behavior: "smooth" });
  }, [shown?.id]);
  useEffect(() => {
    const el = ref.current;
    if (!el || !shoot?.session.showNewestCapture) return;
    if (vertical) el.scrollTo({ top: el.scrollHeight, behavior: "smooth" });
    else el.scrollTo({ left: el.scrollWidth, behavior: "smooth" });
  }, [count, vertical, shoot?.session.showNewestCapture]);

  if (!shoot) return null;
  const pairCount = (item: CaptureItem) => items.filter((i) => i.pairKey === item.pairKey).length;
  return (
    <div className={`filmstrip${vertical ? " vertical" : ""}`} aria-label={`Filmstrip, ${count} captures`}>
      <div className="filmstrip-scroll" ref={ref}>
        {items.length === 0 ? <div className="filmstrip-empty t-hud ink-2">{vertical ? "" : "Frames land here"}</div> : null}
        {items.map((item) => (
          <FilmCell key={item.id} item={item} selected={item.id === shown?.id} pairCount={pairCount(item)} />
        ))}
      </div>
      {unseen > 0 ? (
        <button className="unseen-badge" onClick={() => useApp.getState().showNewest()} aria-label={`${unseen} new frames, show the newest`}>
          {unseen} new
        </button>
      ) : null}
    </div>
  );
}

function FilmCell({ item, selected, pairCount }: { item: CaptureItem; selected: boolean; pairCount: number }) {
  const ready = isReady(item);
  return (
    <button
      data-id={item.id}
      className={`film-cell${selected ? " selected" : ""}${ready ? "" : " pending"}`}
      onClick={() => ready && useApp.getState().shootSelect(item.id)}
      onDoubleClick={() => ready && useApp.getState().openModal({ kind: "loupe", origin: "shoot" })}
      onContextMenu={(e) => openContextMenu(e, commandItems(commandsFor("shoot", [item.id]), (c) => runCommand(c, [item.id], "shoot"), ["select.", "camera.", "session."]))}
      aria-label={`${item.filename}${!ready ? (isFailed(item) ? ", failed" : ", downloading") : ""}${item.rating ? `, ${item.rating} stars` : ""}`}
      aria-pressed={selected}
    >
      <CaptureImage item={item} variant="thumb" style={{ opacity: item.flag === "reject" ? 0.4 : undefined }} />
      {!ready ? <span className="tile-dim" /> : null}
      {isFailed(item) ? (
        <Icon name="exclamationmark.triangle.fill" size={18} className="c-danger tile-center" />
      ) : !ready ? (
        <span className="tile-center"><ProgressRing progress={downloadProgress(item)} size={24} /></span>
      ) : null}
      <TileBadges item={item} pairCount={pairCount} compact />
    </button>
  );
}
