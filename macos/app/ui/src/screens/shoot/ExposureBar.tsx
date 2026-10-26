import { Cap, EXPOSURE_BAR, hasCap, isLiveStatus, propertyChoices, type PropertyDescriptor, type TetherProperty } from "../../api";
import { useApp } from "../../state/store";

export const PROPERTY_CAPTIONS: Partial<Record<TetherProperty, string>> = {
  shutterSpeed: "Shutter", aperture: "Aperture", iso: "ISO", exposureCompensation: "EV", whiteBalance: "WB", captureDestination: "Saves to",
};

/** Shown values: "ISO 400" stays "400" under an ISO caption; EV gets its sign. */
export function exposureValue(p: TetherProperty, display: string | undefined): string {
  if (!display) return "—";
  if (p === "exposureCompensation" && display !== "0" && !display.startsWith("+") && !display.startsWith("-") && !display.startsWith("−")) return `+${display}`;
  return display;
}

/**
 * Chips for the exposure properties the camera reports (never invented), plus
 * the capture destination. Read-only, not greyed into noise, when the body
 * offers no property control.
 */
export function ExposureBar({ grid }: { grid?: boolean }) {
  const shoot = useApp((s) => s.shoot);
  const top = useApp((s) => s.modals.at(-1));
  if (!shoot?.identity) return null;
  const control = hasCap(shoot.identity.capabilities, Cap.propertyControl) && isLiveStatus(shoot.status);
  const props = [...EXPOSURE_BAR, "captureDestination" as TetherProperty]
    .map((p) => shoot.properties.find((d) => d.property === p))
    .filter((d): d is PropertyDescriptor => !!d);
  return (
    <div className={grid ? "exposure-grid" : "exposure-row"} aria-label={control ? "Exposure settings" : "Exposure settings, read only on this camera"}>
      {props.map((d) => {
        const writable = d.isWritable && propertyChoices(d).length > 0 && control;
        const picking = top?.kind === "property" && top.property === d.property;
        return (
          <button
            key={d.property}
            className={`exposure-chip${picking ? " selected" : ""}`}
            disabled={!writable}
            onClick={() => useApp.getState().openModal({ kind: "property", property: d.property })}
            aria-label={`${PROPERTY_CAPTIONS[d.property] ?? d.property} ${d.display}`}
          >
            <span className="t-caption">{PROPERTY_CAPTIONS[d.property] ?? d.property}</span>
            <span className="t-exposure">{exposureValue(d.property, d.display)}</span>
          </button>
        );
      })}
    </div>
  );
}
