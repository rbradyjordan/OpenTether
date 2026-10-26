import { useEffect, useState } from "react";
import { api, errorMessage, type CatalogChange, type CatalogPreview } from "../../api";
import { useApp } from "../../state/store";
import { Sheet, SheetActions } from "../../components/Sheet";
import { IconTile, Spinner } from "../../components/common";
import { Icon } from "../../components/Icon";
import { plural } from "../../lib/format";

function describe(c: CatalogChange): string {
  const parts: string[] = [];
  if (c.rating != null) parts.push(c.rating === 0 ? "no stars" : `${c.rating}★`);
  if (c.flag) parts.push(c.flag === "pick" ? "pick" : c.flag === "reject" ? "reject" : "unflagged");
  if (c.label) parts.push(c.label === "none" ? "no label" : c.label);
  if (c.newKeywords.length) parts.push(c.newKeywords.join(", "));
  return parts.join(" · ");
}

/** Brings culling done in Lightroom Classic or Capture One back: preview, then apply as undoable steps. */
export function CatalogSync({ path, onClose }: { path: string; onClose: () => void }) {
  const [preview, setPreview] = useState<CatalogPreview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [applying, setApplying] = useState(false);
  useEffect(() => {
    api.catalogRead({ path }).then(setPreview).catch((e) => setError(errorMessage(e)));
  }, [path]);

  const changes = preview?.changes ?? [];
  const counts = {
    ratings: changes.filter((c) => c.rating != null).length,
    flags: changes.filter((c) => c.flag != null).length,
    labels: changes.filter((c) => c.label != null).length,
    keywords: changes.reduce((a, c) => a + c.newKeywords.length, 0),
  };
  const apply = async () => {
    setApplying(true);
    try {
      await api.catalogApply({ changes });
      onClose();
    } catch (e) {
      setError(errorMessage(e));
      useApp.getState().fail(e);
    } finally {
      setApplying(false);
    }
  };

  return (
    <Sheet title="Sync from catalog" onClose={onClose} width={560}
      footer={<SheetActions onCancel={onClose} primaryTitle={applying ? "Applying…" : "Apply"} onPrimary={apply} primaryDisabled={!changes.length || applying} />}>
      <div className="row gap-m">
        <IconTile name={preview?.kind === "captureOne" ? "camera.aperture" : "books.vertical"} active size={40} />
        <div className="col" style={{ gap: 0 }}>
          <span className="t-headline">{preview?.name ?? path.split("/").pop()}</span>
          <span className="t-hud ink-1">{preview ? (preview.kind === "captureOne" ? "Capture One catalog" : "Lightroom Classic catalog") : "Catalog"}</span>
        </div>
      </div>
      {preview?.openElsewhere ? <div className="row c-warn t-callout"><Icon name="info.circle" size={14} /> Lightroom has this catalog open. Showing everything it has saved so far.</div> : null}
      {preview?.kind === "captureOne" ? <div className="row t-callout"><Icon name="flask" size={14} /> Capture One support is experimental: ratings and colour tags are read; keywords are not.</div> : null}
      {!preview && !error ? <div className="row t-callout"><Spinner small /> Reading the catalog…</div> : null}
      {error ? <div className="c-danger t-callout">{error}</div> : null}
      {preview && !changes.length ? <div className="row c-ok"><Icon name="checkmark.circle.fill" size={16} /> Everything already matches.</div> : null}
      {changes.length ? (
        <>
          <div className="col" style={{ gap: 4 }}>
            <span className="t-caption">{plural(changes.length, "frame")} will change</span>
            <div className="form-group" style={{ background: "var(--surface-2)", borderRadius: 12, padding: "4px 12px" }}>
              {([["Star ratings", counts.ratings, "star.fill"], ["Picks and rejects", counts.flags, "flag.fill"], ["Colour labels", counts.labels, "circle.fill"], ["New keywords", counts.keywords, "tag.fill"]] as const).map(([t, n, icon]) => (
                <div key={t} className="form-row">
                  <Icon name={icon} size={14} className="ink-1" />
                  <span className="form-label">{t}</span>
                  <span className="num ink-1">{n}</span>
                </div>
              ))}
            </div>
          </div>
          <div className="col" style={{ gap: 2 }}>
            <span className="t-caption">Frames</span>
            {changes.slice(0, 200).map((c) => (
              <div key={c.captureId} className="col" style={{ gap: 0, padding: "4px 0" }}>
                <span className="t-callout ink-0">{c.filename}</span>
                <span className="t-hud ink-1">{describe(c)}</span>
              </div>
            ))}
          </div>
        </>
      ) : null}
      {preview?.unmatched.length ? (
        <div className="t-hud ink-2">{plural(preview.unmatched.length, "photo")} in the catalog are not in Open Tether and were left alone.</div>
      ) : null}
    </Sheet>
  );
}
