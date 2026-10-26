import { useEffect, useRef } from "react";
import { propertyChoices, type TetherProperty } from "../../api";
import { useApp } from "../../state/store";
import { Sheet } from "../../components/Sheet";
import { PROPERTY_CAPTIONS, exposureValue } from "./ExposureBar";

/**
 * The camera's own list of values as a wheel: the current value starts
 * centred; click a value, scroll, or use ↑/↓ to step — each step applies.
 */
export function PropertyPicker({ property, onClose }: { property: TetherProperty; onClose: () => void }) {
  const desc = useApp((s) => s.shoot?.properties.find((p) => p.property === property));
  const choices = propertyChoices(desc);
  const index = desc ? choices.findIndex((c) => c.raw === desc.raw) : -1;
  const listRef = useRef<HTMLDivElement>(null);
  // Where the wheel is heading: key repeats step from here, not from the last value the camera confirmed.
  const target = useRef(index);
  useEffect(() => {
    target.current = index;
  }, [index]);

  useEffect(() => {
    const el = listRef.current?.querySelector<HTMLElement>(`[data-i="${index}"]`);
    el?.scrollIntoView({ block: "center", behavior: "smooth" });
  }, [index]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return;
      e.preventDefault();
      const i = target.current + (e.key === "ArrowDown" ? 1 : -1);
      const next = choices[i];
      if (!next) return;
      target.current = i;
      useApp.getState().setProperty(property, next.raw);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [choices, property]);

  return (
    <Sheet
      title={PROPERTY_CAPTIONS[property] ?? property}
      subtitle="↑ ↓ to step · Esc when done"
      onClose={onClose}
      width={320}
      height={460}
      headerTrailing={<span className="t-exposure" style={{ marginRight: 8 }}>{exposureValue(property, desc?.display)}</span>}
      bodyStyle={{ padding: 0 }}
    >
      {choices.length ? (
        <div className="wheel" ref={listRef}>
          <div className="wheel-pad" />
          {choices.map((c, i) => (
            <button
              key={String(c.raw)}
              data-i={i}
              className={`wheel-item${i === index ? " current" : ""}`}
              style={{ opacity: Math.max(0.3, 1 - Math.abs(i - index) * 0.14) }}
              onClick={() => useApp.getState().setProperty(property, c.raw)}
            >
              {exposureValue(property, c.display)}
            </button>
          ))}
          <div className="wheel-pad" />
          <div className="wheel-band" aria-hidden />
        </div>
      ) : (
        <div className="t-callout" style={{ padding: 24, textAlign: "center" }}>This setting is not available right now.</div>
      )}
    </Sheet>
  );
}
