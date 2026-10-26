import { useState } from "react";
import { api, errorMessage, isReady, type CaptureItem } from "../../api";
import { useApp } from "../../state/store";
import { Sheet, SheetActions } from "../../components/Sheet";
import { Slider } from "../../components/controls";
import { CaptureImage } from "../../components/media";

function Picker({ title, items, value, onPick }: { title: string; items: CaptureItem[]; value: string | null; onPick: (id: string) => void }) {
  return (
    <div className="col" style={{ gap: 6 }}>
      <span className="t-callout ink-0" style={{ fontWeight: 500 }}>{title}</span>
      <div className="match-strip">
        {items.map((i) => (
          <button key={i.id} className={`match-thumb${value === i.id ? " selected" : ""}`} aria-label={i.filename} aria-pressed={value === i.id} onClick={() => onPick(i.id)}>
            <CaptureImage item={i} variant="thumb" />
          </button>
        ))}
      </div>
    </div>
  );
}

/** Pick a reference and a target; the match is computed by the engine and saved as a look. */
export function ColorMatch({ targetId, onClose }: { targetId: string | null; onClose: () => void }) {
  const shoot = useApp((s) => s.shoot);
  const libraryItems = useApp((s) => s.library.items);
  const items = (shoot ? shoot.items : libraryItems).filter((i) => isReady(i) && i.kind !== "raw");
  const [target, setTarget] = useState<string | null>(targetId ?? items.at(-1)?.id ?? null);
  const [reference, setReference] = useState<string | null>(items.find((i) => i.id !== target)?.id ?? null);
  const [strength, setStrength] = useState(0.8);
  const [working, setWorking] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const run = async () => {
    if (!reference || !target) return;
    setWorking(true);
    setError(null);
    try {
      const look = await api.lookColorMatch({ referenceId: reference, targetId: target, strength });
      if (shoot) useApp.getState().setLook({ lookId: look.id, strength: 1 });
      useApp.getState().toast(`Saved look ${look.name}`, "wand.and.stars");
      onClose();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setWorking(false);
    }
  };

  return (
    <Sheet title="Colour match" onClose={onClose} width={640}
      footer={<SheetActions onCancel={onClose} primaryTitle={working ? "Matching…" : "Match and apply"} onPrimary={run} primaryDisabled={working || !reference || !target || reference === target} />}>
      <Picker title="Reference (the look you want)" items={items} value={reference} onPick={setReference} />
      <Picker title="Target (a frame from this session)" items={items} value={target} onPick={setTarget} />
      <div className="col" style={{ gap: 4 }}>
        <span className="t-callout ink-0">Strength {Math.round(strength * 100)}%</span>
        <Slider label="Strength" value={strength} min={0.1} max={1} step={0.05} onChange={setStrength} />
      </div>
      {error ? <div className="t-callout c-danger">{error}</div> : null}
    </Sheet>
  );
}
