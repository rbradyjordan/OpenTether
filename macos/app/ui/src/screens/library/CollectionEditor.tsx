import { useEffect, useState } from "react";
import { api, type Collection } from "../../api";
import { useApp } from "../../state/store";
import { Sheet, SheetActions } from "../../components/Sheet";
import { Icon } from "../../components/Icon";
import { ColorLabelPicker } from "../../components/review";
import { Labeled, TextField } from "../../components/controls";
import { FilterChips } from "./FilterChips";
import { filterSummary } from "../../lib/filter";
import { plural } from "../../lib/format";

export const COLLECTION_SYMBOLS = ["rectangle.stack", "star", "heart", "flag", "person.crop.rectangle", "camera", "sparkles.rectangle.stack",
  "folder", "tag", "sun.max", "moon", "paintpalette", "bolt", "leaf", "building.2", "airplane"];

export function SymbolPicker({ selected, onPick }: { selected: string; onPick: (s: string) => void }) {
  return (
    <div className="symbol-grid" role="radiogroup" aria-label="Symbol">
      {COLLECTION_SYMBOLS.map((s) => (
        <button key={s} type="button" role="radio" aria-checked={selected === s} aria-label={s.replace(/\./g, " ")} className={`symbol-cell${selected === s ? " on" : ""}`} onClick={() => onPick(s)}>
          <Icon name={s} size={17} />
        </button>
      ))}
    </div>
  );
}

/** Create or edit a collection: name, symbol, tint; smart collections edit their rule with the grid's chips and a live count. */
export function CollectionEditor({ draft: initial, pendingIds, onClose }: { draft: Collection; pendingIds?: string[]; onClose: () => void }) {
  const sources = useApp((s) => s.sources);
  const [draft, setDraft] = useState(initial);
  const [count, setCount] = useState<number | null>(null);
  const isNew = !sources || ![...sources.builtIns, ...sources.manual, ...sources.smart].some((c) => c.id === initial.id);
  const smart = draft.kind === "smart";

  useEffect(() => {
    if (!smart) return;
    let live = true;
    api.libraryPreviewCount({ filter: draft.rule ?? {} }).then((n) => live && setCount(n));
    return () => {
      live = false;
    };
  }, [smart, draft.rule]);

  const save = async () => {
    const s = useApp.getState();
    const c = { ...draft, name: draft.name.trim() };
    try {
      if (isNew && !smart) await api.collectionCreate({ name: c.name, ids: pendingIds ?? [], symbol: c.symbol, tint: c.tint });
      else await api.collectionSave({ collection: c });
      s.toast(isNew ? `Created ${c.name}` : `Saved ${c.name}`, c.symbol);
      onClose();
    } catch (e) {
      s.fail(e);
    }
  };

  return (
    <Sheet
      title={isNew ? (smart ? "New smart collection" : "New collection") : "Edit collection"}
      subtitle={pendingIds?.length ? `With ${plural(pendingIds.length, "photo")}` : undefined}
      onClose={onClose}
      width={smart ? 640 : 480}
      footer={<SheetActions onCancel={onClose} primaryTitle={isNew ? "Create" : "Save"} onPrimary={save} primaryDisabled={!draft.name.trim()} />}
    >
      <Labeled label="Name">
        <TextField value={draft.name} onChange={(name) => setDraft({ ...draft, name })} placeholder={smart ? "Smart collection" : "Collection"} autoFocus disabled={draft.isBuiltIn} onSubmit={() => draft.name.trim() && save()} />
      </Labeled>
      <Labeled label="Symbol and colour">
        <SymbolPicker selected={draft.symbol} onPick={(symbol) => setDraft({ ...draft, symbol })} />
        <div style={{ marginTop: 6 }}><ColorLabelPicker current={draft.tint} onPick={(tint) => setDraft({ ...draft, tint })} /></div>
      </Labeled>
      {smart ? (
        <div className="col" style={{ gap: 8 }}>
          <span className="t-caption">Rule</span>
          <FilterChips wrap filter={draft.rule ?? {}} onChange={(rule) => setDraft({ ...draft, rule })} sessions={sources?.sessions ?? []} cameras={sources?.cameras ?? []} />
          <span className="t-callout">{filterSummary(draft.rule ?? {})}</span>
          <span className="t-hud ink-2">{count == null ? "Counting…" : `${plural(count, "photo")} match right now`}</span>
        </div>
      ) : null}
    </Sheet>
  );
}
