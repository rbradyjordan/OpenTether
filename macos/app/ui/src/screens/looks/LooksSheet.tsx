import { useEffect, useState } from "react";
import { api, isReady, type CaptureItem, type LookDescriptor } from "../../api";
import { useApp, displayedItem } from "../../state/store";
import { Sheet } from "../../components/Sheet";
import { Slider } from "../../components/controls";
import { CaptureImage } from "../../components/media";
import { Icon } from "../../components/Icon";

const STOPS = [0, 0.5, 1];

/** Snaps the strength slider onto 0 / 50 / 100 % within ±3 %. */
export function snapStrength(v: number): number {
  for (const s of STOPS) if (Math.abs(v - s) <= 0.03) return s;
  return v;
}

function LookTile({ item, look, name, family, selected, onPick }: { item: CaptureItem | null; look: LookDescriptor | null; name: string; family: string; selected: boolean; onPick: () => void }) {
  const hint = look?.hint;
  const swatch = hint
    ? `hsl(${hint.warmth >= 0 ? 30 : 210}, ${Math.round(Math.min(1, Math.abs(hint.warmth) * 0.6 + 0.2) * 100)}%, ${Math.round((0.45 + hint.contrast * 0.15) * 100)}%)`
    : "var(--surface-3)";
  return (
    <button className={`look-tile${selected ? " selected" : ""}`} onClick={onPick} aria-label={`${name} look${family ? `, ${family}` : ""}`} aria-pressed={selected}>
      <span className="look-thumb" style={{ background: item ? undefined : swatch }}>
        {item ? <CaptureImage item={item} variant="thumb" look={look ? { lookId: look.id, strength: 1 } : null} /> : null}
        {selected ? <Icon name="checkmark.circle.fill" size={18} className="look-check" /> : null}
      </span>
      <span className="t-hud ink-0 truncate">{name}</span>
      <span className="t-caption truncate">{family || " "}</span>
    </button>
  );
}

/** Look tiles rendered on the current frame, plus a strength slider. */
export function LooksSheet({ onClose }: { onClose: () => void }) {
  const shoot = useApp((s) => s.shoot);
  const looks = useApp((s) => s.looks);
  const item = displayedItem(shoot);
  const [strength, setStrength] = useState(shoot?.look.strength ?? 1);
  const selectedId = shoot?.look.lookId ?? null;
  useEffect(() => setStrength(shoot?.look.strength ?? 1), [shoot?.look.strength]);

  const apply = (lookId: string | null, s = strength) => useApp.getState().setLook({ lookId, strength: s });
  const families = [...new Set(looks.map((l) => l.family))];

  return (
    <Sheet
      title="Looks"
      onClose={onClose}
      width={640}
      height="min(720px, calc(100vh - 48px))"
      headerTrailing={
        <button className="btn secondary small" onClick={async () => {
          const paths = await api.dialogPick({ kind: "cube", multiple: true });
          if (paths.length) await api.looksImportCube({ paths }).catch(useApp.getState().fail);
        }}>
          <Icon name="square.and.arrow.down" size={13} /> Import .cube LUT
        </button>
      }
    >
      {families.map((fam, fi) => (
        <div key={fam} className="col" style={{ gap: 8 }}>
          <span className="t-caption">{fam}</span>
          <div className="look-grid">
            {fi === 0 ? <LookTile item={item} look={null} name="None" family="" selected={selectedId == null} onPick={() => apply(null)} /> : null}
            {looks.filter((l) => l.family === fam).map((l) => (
              <LookTile key={l.id} item={item} look={l} name={l.name} family={l.family} selected={selectedId === l.id} onPick={() => apply(l.id)} />
            ))}
          </div>
        </div>
      ))}
      {selectedId ? (
        <div className="card col" style={{ gap: 6 }}>
          <div className="row">
            <span className="t-caption">Strength</span>
            <span className="spacer" />
            <span className="t-exposure">{Math.round(strength * 100)}%</span>
          </div>
          <Slider label="Strength" value={strength} min={0} max={1} onChange={(v) => {
            const s = snapStrength(v);
            setStrength(s);
            apply(selectedId, s);
          }} />
        </div>
      ) : null}
      <div className="t-hud ink-2">Looks apply to the canvas, new captures and exports with "Apply look" on. Originals are never changed.</div>
      <button className="btn secondary" disabled={!(shoot?.items.filter(isReady).length ?? 0)} onClick={() => useApp.getState().openModal({ kind: "colorMatch", targetId: item?.id ?? null })}>
        <Icon name="wand.and.stars" size={14} /> Colour match from a reference frame
      </button>
    </Sheet>
  );
}
