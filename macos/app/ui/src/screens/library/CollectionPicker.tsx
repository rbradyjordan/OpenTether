import { useEffect, useState } from "react";
import { api, sourceKey, type Collection } from "../../api";
import { useApp } from "../../state/store";
import { Sheet } from "../../components/Sheet";
import { Icon } from "../../components/Icon";
import { labelColor } from "../../components/review";
import { newCollectionDraft } from "../../commands/dispatcher";
import { plural } from "../../lib/format";

/** "Add to collection…": recent collections first, then the rest, plus "new collection with these". */
export function CollectionPicker({ ids, onClose }: { ids: string[]; onClose: () => void }) {
  const sources = useApp((s) => s.sources);
  const [recentIds, setRecentIds] = useState<string[]>([]);
  useEffect(() => {
    api.recentsGet().then((r) => setRecentIds(r.collectionIds));
  }, []);
  const manual = sources?.manual ?? [];
  const recent = recentIds.map((id) => manual.find((c) => c.id === id)).filter((c): c is Collection => !!c);
  const others = manual.filter((c) => !recentIds.includes(c.id));

  const row = (c: Collection) => (
    <button key={c.id} className="list-row interactive" onClick={() => { useApp.getState().addToCollection(ids, c.id); onClose(); }}>
      <Icon name={c.symbol} size={16} style={{ color: c.tint !== "none" ? labelColor(c.tint) : "var(--ink-1)" }} />
      <span className="fill truncate">{c.name}</span>
      <span className="t-hud ink-2">{sources?.counts[sourceKey({ kind: "collection", id: c.id })] ?? 0}</span>
    </button>
  );

  return (
    <Sheet title="Add to collection" subtitle={plural(ids.length, "photo")} onClose={onClose} width={420}>
      {recent.length ? (
        <div className="col" style={{ gap: 2 }}>
          <span className="t-caption">Recent</span>
          {recent.map(row)}
        </div>
      ) : null}
      <div className="col" style={{ gap: 2 }}>
        <span className="t-caption">{recent.length ? "All" : "Collections"}</span>
        {others.map(row)}
        {!manual.length ? <span className="t-callout">No collections yet. Smart collections fill themselves; create a plain one for hand picks.</span> : null}
      </div>
      <button
        className="btn secondary"
        onClick={() => {
          onClose();
          useApp.getState().openModal({ kind: "collectionEditor", draft: newCollectionDraft("manual"), pendingIds: ids });
        }}
      >
        <Icon name="plus" size={14} /> New collection with {ids.length === 1 ? "this photo" : `these ${ids.length} photos`}
      </button>
    </Sheet>
  );
}
