import { useEffect, useState } from "react";
import { api } from "../../api";
import { useApp } from "../../state/store";
import { Icon } from "../../components/Icon";
import { Sheet, SheetActions } from "../../components/Sheet";
import { normalizeTag } from "../../lib/filter";
import { plural } from "../../lib/format";

/** Tag chips with an entry field, autocomplete, and recent tags as one-click chips. */
export function TagEditor({ tags, onAdd, onRemove, autoFocus }: { tags: string[]; onAdd: (t: string) => void; onRemove: (t: string) => void; autoFocus?: boolean }) {
  const [text, setText] = useState("");
  const [matches, setMatches] = useState<string[]>([]);
  const [recent, setRecent] = useState<string[]>([]);
  useEffect(() => {
    api.recentsGet().then((r) => setRecent(r.tags));
  }, [tags.length]);
  useEffect(() => {
    let live = true;
    if (!text.trim()) {
      setMatches([]);
      return;
    }
    api.tagsSuggest({ prefix: text }).then((m) => live && setMatches(m.filter((t) => !tags.includes(t))));
    return () => {
      live = false;
    };
  }, [text, tags]);

  const add = (raw: string) => {
    const t = normalizeTag(raw);
    if (!t) return;
    onAdd(t);
    setText("");
  };
  const suggestions = matches.length ? matches.slice(0, 8) : recent.filter((t) => !tags.includes(t)).slice(0, 8);
  return (
    <div className="col" style={{ gap: 8 }}>
      {tags.length ? (
        <div className="row wrap" style={{ gap: 4 }}>
          {tags.map((t) => (
            <button key={t} className="chip selected" onClick={() => onRemove(t)} aria-label={`Remove tag ${t}`} title="Remove">
              #{t} <Icon name="xmark" size={10} strokeWidth={2.4} />
            </button>
          ))}
        </div>
      ) : null}
      <div className="row">
        <input
          className="field"
          placeholder="Add tag"
          aria-label="New tag"
          autoFocus={autoFocus}
          value={text}
          spellCheck={false}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              add(text);
            }
          }}
        />
        <button className="icon-btn" aria-label="Add tag" disabled={!text.trim()} onClick={() => add(text)}>
          <Icon name="plus.circle.fill" size={20} className="c-accent" />
        </button>
      </div>
      {suggestions.length ? (
        <>
          {!matches.length ? <span className="t-caption">Recent</span> : null}
          <div className="row wrap" style={{ gap: 4 }}>
            {suggestions.map((t) => (
              <button key={t} className="chip" onClick={() => add(t)} aria-label={`Add tag ${t}`}>
                #{t} <Icon name="plus" size={10} strokeWidth={2.4} />
              </button>
            ))}
          </div>
        </>
      ) : null}
    </div>
  );
}

/** "Add tags…" for a batch: collects tags, then applies them in one undoable step. */
export function TagSheet({ ids, onClose }: { ids: string[]; onClose: () => void }) {
  const [added, setAdded] = useState<string[]>([]);
  const apply = () => {
    useApp.getState().addTags(ids, added);
    onClose();
  };
  return (
    <Sheet title="Add tags" subtitle={`For ${plural(ids.length, "photo")}`} onClose={onClose} width={460}
      footer={<SheetActions onCancel={onClose} primaryTitle="Add" onPrimary={apply} primaryDisabled={!added.length} />}>
      <TagEditor autoFocus tags={added} onAdd={(t) => setAdded((a) => (a.includes(t) ? a : [...a, t]))} onRemove={(t) => setAdded((a) => a.filter((x) => x !== t))} />
    </Sheet>
  );
}
