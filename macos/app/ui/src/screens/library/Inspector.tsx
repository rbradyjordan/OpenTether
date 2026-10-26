import { useEffect, useState } from "react";
import { api, cameraDisplayName, exposureLine, type CaptureDetails } from "../../api";
import { useApp, inspectedItem, libraryTargets } from "../../state/store";
import { CaptureImage } from "../../components/media";
import { ColorLabelPicker, ReviewRow } from "../../components/review";
import { EmptyState, SectionCard } from "../../components/common";
import { Icon } from "../../components/Icon";
import { TagEditor } from "./TagEditor";
import { formatBytes, formatDateTime, formatFull } from "../../lib/format";

function Fact({ label, value }: { label: string; value: string }) {
  return (
    <div className="fact">
      <span className="t-caption">{label}</span>
      <span className="t-callout ink-0 num selectable">{value}</span>
    </div>
  );
}

/** Right column: describes the focused frame; every control goes through the review editor (undoable). */
export function Inspector() {
  const library = useApp((s) => s.library);
  const sources = useApp((s) => s.sources);
  const looks = useApp((s) => s.looks);
  const item = inspectedItem(library);
  const ids = libraryTargets(library);
  const [details, setDetails] = useState<CaptureDetails | null>(null);
  const st = useApp.getState;

  const detailsKey = item ? `${item.id}|${item.rating}|${item.flag}|${item.colorLabel}` : "";
  useEffect(() => {
    if (!item) {
      setDetails(null);
      return;
    }
    let live = true;
    api.captureDetails({ id: item.id }).then((d) => live && setDetails(d)).catch(() => live && setDetails(null));
    const un = api.on("captures:changed", (changed) => {
      if (changed.some((c) => c.id === item.id)) api.captureDetails({ id: item.id }).then((d) => live && setDetails(d));
    });
    return () => {
      live = false;
      un();
    };
  }, [detailsKey]);

  if (!item) {
    return (
      <aside className="inspector">
        <EmptyState icon="sidebar.right" title="Nothing selected" message="Click a photo to inspect it." />
      </aside>
    );
  }

  const session = sources?.sessions.find((s) => s.id === item.sessionId);
  const camera = sources?.cameras.find((c) => c.id === item.cameraId);
  const look = looks.find((l) => l.id === item.lookId);
  const exif = details?.exif;
  const allCollections = sources ? [...sources.manual] : [];
  return (
    <aside className="inspector" aria-label="Inspector">
      <div className="inspector-scroll">
        <button className="inspector-preview" onClick={() => st().setLoupe(item.id)} aria-label={`Preview of ${item.filename}, opens the loupe`}>
          <CaptureImage key={item.id} item={item} variant="preview" fit="contain" lazy={false} />
        </button>
        {library.selection.ids.length > 1 ? (
          <div className="t-hud ink-1">{library.selection.ids.length} selected · showing {item.filename}</div>
        ) : null}
        <SectionCard>
          <div className="t-headline truncate selectable">{item.filename}</div>
          <Fact label="Session" value={session?.name ?? "—"} />
          <Fact label="Camera" value={camera ? cameraDisplayName(camera) : exif?.model ?? "—"} />
          {exif?.lens ? <Fact label="Lens" value={exif.lens} /> : null}
          {exposureLine(item.exposure) ? <Fact label="Exposure" value={exposureLine(item.exposure)} /> : exif?.exposureLine ? <Fact label="Exposure" value={exif.exposureLine} /> : null}
          {exif?.dateTimeOriginal ? <Fact label="EXIF time" value={formatFull(exif.dateTimeOriginal)} /> : null}
          <Fact label="Size" value={`${item.width} × ${item.height} · ${formatBytes(item.bytes)}`} />
          <Fact label="Captured" value={formatFull(item.capturedAt)} />
          <Fact label="Look" value={look?.name ?? (item.lookId ? "Applied" : "None")} />
          {item.kind === "raw" ? <Fact label="Kind" value="RAW" /> : null}
        </SectionCard>
        <SectionCard title="Review" icon="star">
          <ReviewRow item={item} size={20} onRate={(n) => st().rate(ids, n)} onFlag={(f) => st().flag(ids, f)} />
          <ColorLabelPicker current={item.colorLabel} onPick={(l) => st().label(ids, l)} />
        </SectionCard>
        <SectionCard title="Tags" icon="number">
          <TagEditor tags={details?.tags ?? []} onAdd={(t) => st().addTags(ids, [t])} onRemove={(t) => st().removeTags(ids, [t])} />
        </SectionCard>
        <SectionCard title="Collections" icon="rectangle.stack">
          {(details?.collectionIds ?? []).map((cid) => {
            const c = allCollections.find((x) => x.id === cid);
            if (!c) return null;
            return (
              <div key={cid} className="row">
                <Icon name={c.symbol} size={14} className="ink-1" />
                <span className="fill truncate">{c.name}</span>
                <button className="icon-btn" aria-label={`Remove from ${c.name}`} title={`Remove from ${c.name}`} onClick={() => st().removeFromCollection(ids, cid)}>
                  <Icon name="minus.circle" size={15} />
                </button>
              </div>
            );
          })}
          <button className="btn plain small" style={{ alignSelf: "flex-start", paddingLeft: 0 }} onClick={() => st().openModal({ kind: "collectionPicker", ids })}>
            <Icon name="plus" size={13} /> Add to collection…
          </button>
        </SectionCard>
        <SectionCard title="Export history" icon="square.and.arrow.up">
          {details?.exportHistory.length ? (
            details.exportHistory.map((h, i) => (
              <div key={i} className="row">
                <span className="fill">{h.destination[0].toUpperCase() + h.destination.slice(1)}</span>
                <span className="t-hud ink-1">{formatDateTime(h.at)}</span>
              </div>
            ))
          ) : (
            <span className="t-callout">Not exported yet</span>
          )}
        </SectionCard>
        <div className="row wrap" style={{ gap: 8 }}>
          <button className="btn secondary small" onClick={() => st().revealInSession(item)}>
            <Icon name="rectangle.stack.badge.person.crop" size={14} /> Reveal in session
          </button>
          <button className="btn secondary small" onClick={() => api.revealInFinder({ captureId: item.id })}>
            <Icon name="folder" size={14} /> Show in Finder
          </button>
        </div>
      </div>
    </aside>
  );
}

