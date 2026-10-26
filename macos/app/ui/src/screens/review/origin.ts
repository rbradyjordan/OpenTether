import { isReady, type CaptureItem, type LookStack } from "../../api";
import { useApp, displayedItem, visibleTiles } from "../../state/store";
import type { Origin } from "../../state/types";
import type { Surface } from "../../commands/dispatcher";

export interface OriginList {
  items: CaptureItem[];
  current: CaptureItem | null;
  look: LookStack | null;
  surface: Surface;
  select(id: string): void;
}

/** The frames a loupe / compare / client review walks through, and which one is showing. */
export function useOrigin(origin: Origin): OriginList {
  const shoot = useApp((s) => s.shoot);
  const library = useApp((s) => s.library);
  const detail = useApp((s) => s.sessionDetail);
  if (origin === "shoot") {
    const items = (shoot?.items ?? []).filter(isReady);
    return {
      items,
      current: displayedItem(shoot),
      look: shoot?.look ?? null,
      surface: "shoot",
      select: (id) => useApp.getState().shootSelect(id),
    };
  }
  const items = origin === "library" ? visibleTiles(library).map((t) => t.item).filter(isReady) : (detail?.items ?? []).filter(isReady);
  const current = items.find((i) => i.id === library.loupeId) ?? items[0] ?? null;
  return {
    items,
    current,
    look: null,
    surface: origin === "library" ? "library" : "session",
    select: (id) =>
      useApp.setState((s) => ({
        library: origin === "library"
          ? { ...s.library, loupeId: id, focusedId: id, scrollToId: id, selection: { ids: [id], anchor: id } }
          : { ...s.library, loupeId: id },
      })),
  };
}
