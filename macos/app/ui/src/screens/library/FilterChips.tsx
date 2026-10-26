import { useEffect, useState } from "react";
import { api, COLOR_LABELS, cameraDisplayName, type CameraIdentity, type CaptureFilter, type ColorLabel, type ShootSession } from "../../api";
import { MenuButton, type MenuItem } from "../../components/Menu";
import { Icon } from "../../components/Icon";
import { filterSummary, isEmptyFilter, normalizeTag } from "../../lib/filter";

function toggle<T>(list: T[] | null | undefined, v: T): T[] | null {
  const s = new Set(list ?? []);
  if (s.has(v)) s.delete(v);
  else s.add(v);
  return s.size ? [...s] : null;
}

function Chip({ label, icon, selected, items, minWidth }: { label: string; icon: string; selected: boolean; items: MenuItem[] | (() => MenuItem[]); minWidth?: number }) {
  return (
    <MenuButton className={`chip${selected ? " selected" : ""}`} items={items} minWidth={minWidth ?? 190} label={label}>
      <Icon name={icon} size={12} />
      <span className="truncate" style={{ maxWidth: 180 }}>{label}</span>
      <Icon name="chevron.down" size={10} strokeWidth={2.2} />
    </MenuButton>
  );
}

function TagEntry({ filter, onChange, close }: { filter: CaptureFilter; onChange: (f: CaptureFilter) => void; close: () => void }) {
  const [text, setText] = useState("");
  const [suggestions, setSuggestions] = useState<string[]>([]);
  useEffect(() => {
    let live = true;
    api.tagsSuggest({ prefix: text }).then((s) => live && setSuggestions(s.filter((t) => !(filter.tagsAll ?? []).includes(t))));
    return () => {
      live = false;
    };
  }, [text, filter.tagsAll]);
  const add = (raw: string) => {
    const t = normalizeTag(raw);
    if (!t) return;
    onChange({ ...filter, tagsAll: [...new Set([...(filter.tagsAll ?? []), t])] });
    close();
  };
  return (
    <div className="col" style={{ gap: 6, width: 240 }} onKeyDown={(e) => e.stopPropagation()}>
      <input
        className="field"
        autoFocus
        placeholder="Tag"
        aria-label="Filter by tag"
        value={text}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") add(text);
          if (e.key === "Escape") close();
        }}
      />
      <div className="row wrap" style={{ gap: 4 }}>
        {suggestions.slice(0, 8).map((t) => (
          <button key={t} className="chip" onClick={() => add(t)}>#{t}</button>
        ))}
      </div>
      {(filter.tagsAll ?? []).length ? (
        <div className="row wrap" style={{ gap: 4 }}>
          {(filter.tagsAll ?? []).map((t) => (
            <button key={t} className="chip selected" onClick={() => onChange({ ...filter, tagsAll: toggle(filter.tagsAll, t) })}>
              #{t} <Icon name="xmark" size={10} />
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}

/** The chips over a `CaptureFilter`: live on the grid, and inside the smart-collection editor on a draft. */
export function FilterChips({
  filter, onChange, sessions, cameras, onSaveSmart, wrap,
}: { filter: CaptureFilter; onChange: (f: CaptureFilter) => void; sessions: ShootSession[]; cameras: CameraIdentity[]; onSaveSmart?: () => void; wrap?: boolean }) {
  const f = filter;
  const set = (patch: Partial<CaptureFilter>) => onChange({ ...f, ...patch });
  const flagTitle = !f.flags?.length ? "Flag"
    : f.flags.length === 1 && f.flags[0] === "pick" ? "Picks"
    : f.flags.length === 1 && f.flags[0] === "reject" ? "Rejects"
    : f.flags.length === 1 && f.flags[0] === "none" ? "Unflagged" : "Not rejected";
  const kindTitle = !f.kinds?.length ? "Kind" : f.kinds.includes("raw") ? "RAW" : f.kinds.includes("video") ? "Video" : "JPEG";
  const dateTitle = !f.dateRange ? "Date" : f.dateRange.kind === "today" ? "Today" : f.dateRange.kind === "last7Days" ? "7 days" : f.dateRange.kind === "last30Days" ? "30 days" : "Date range";
  const sessionTitle = !f.sessionIds?.length ? "Session" : f.sessionIds.length === 1 ? sessions.find((s) => s.id === f.sessionIds![0])?.name ?? "1 session" : `${f.sessionIds.length} sessions`;
  const cameraTitle = !f.cameraIds?.length ? "Camera" : f.cameraIds.length === 1 ? (cameras.find((c) => c.id === f.cameraIds![0]) ? cameraDisplayName(cameras.find((c) => c.id === f.cameraIds![0])!) : "1 camera") : `${f.cameraIds.length} cameras`;
  const exportedTitle = f.exportedTo == null ? "Exported?" : f.exportedTo === "never" ? "Not exported" : f.exportedTo === "any" ? "Exported" : `To ${f.exportedTo}`;

  return (
    <div className={`filter-chips${wrap ? " wrap" : ""}`} aria-label={`Filters: ${filterSummary(f)}`}>
      {!isEmptyFilter(f) ? (
        <button className="chip selected" onClick={() => onChange({})} title="Clear all filters">
          <Icon name="xmark.circle.fill" size={12} />
          <span className="truncate" style={{ maxWidth: 240 }}>{filterSummary(f)}</span>
        </button>
      ) : null}
      <Chip
        label={f.minRating != null ? `${f.minRating}★+` : f.maxRating === 0 ? "Unrated" : "Rating"}
        icon="star"
        selected={f.minRating != null || f.maxRating != null}
        items={[
          ...[1, 2, 3, 4, 5].map((n): MenuItem => ({ title: `${"★".repeat(n)} and up`, checked: f.minRating === n, onSelect: () => set({ minRating: n, maxRating: null }) })),
          { title: "Unrated", checked: f.maxRating === 0, onSelect: () => set({ maxRating: 0, minRating: null }) },
          { kind: "divider" },
          { title: "Any rating", onSelect: () => set({ minRating: null, maxRating: null }) },
        ]}
      />
      <Chip
        label={flagTitle}
        icon="flag"
        selected={!!f.flags?.length}
        items={[
          { title: "Picks", icon: "flag.fill", onSelect: () => set({ flags: ["pick"] }) },
          { title: "Rejects", icon: "xmark.circle", onSelect: () => set({ flags: ["reject"] }) },
          { title: "Unflagged", icon: "flag.slash", onSelect: () => set({ flags: ["none"] }) },
          { title: "Not rejected", icon: "checkmark.circle", onSelect: () => set({ flags: ["none", "pick"] }) },
          { kind: "divider" },
          { title: "Any flag", onSelect: () => set({ flags: null }) },
        ]}
      />
      <Chip
        label={f.colors?.length ? [...f.colors].sort().join(", ") : "Colour"}
        icon="circle.lefthalf.filled"
        selected={!!f.colors?.length}
        items={() => [
          ...COLOR_LABELS.map((c): MenuItem => ({
            title: c[0].toUpperCase() + c.slice(1), icon: "circle.fill", iconColor: `var(--label-${c})`, checked: f.colors?.includes(c as ColorLabel),
            onSelect: () => set({ colors: toggle(f.colors, c) }),
          })),
          { kind: "divider" },
          { title: "Any colour", onSelect: () => set({ colors: null }) },
        ]}
      />
      <Chip
        label={kindTitle}
        icon="doc"
        selected={!!f.kinds?.length}
        items={[
          { title: "JPEG / HEIF", onSelect: () => set({ kinds: ["jpeg", "heif", "jpegXL"] }) },
          { title: "RAW", onSelect: () => set({ kinds: ["raw"] }) },
          { title: "Video", onSelect: () => set({ kinds: ["video"] }) },
          { kind: "divider" },
          { title: "Any kind", onSelect: () => set({ kinds: null }) },
        ]}
      />
      <Chip
        label={f.tagsAll?.length ? f.tagsAll.map((t) => `#${t}`).join(" ") : "Tags"}
        icon="number"
        selected={!!f.tagsAll?.length}
        minWidth={260}
        items={[{ kind: "custom", render: (close) => <TagEntry filter={f} onChange={onChange} close={close} /> }]}
      />
      <Chip
        label={dateTitle}
        icon="calendar"
        selected={!!f.dateRange}
        items={[
          { title: "Today", onSelect: () => set({ dateRange: { kind: "today" } }) },
          { title: "Last 7 days", onSelect: () => set({ dateRange: { kind: "last7Days" } }) },
          { title: "Last 30 days", onSelect: () => set({ dateRange: { kind: "last30Days" } }) },
          { kind: "divider" },
          { title: "Any date", onSelect: () => set({ dateRange: null }) },
        ]}
      />
      {sessions.length ? (
        <Chip
          label={sessionTitle}
          icon="rectangle.stack"
          selected={!!f.sessionIds?.length}
          minWidth={240}
          items={() => [
            ...sessions.slice(0, 20).map((s): MenuItem => ({ title: s.name, checked: f.sessionIds?.includes(s.id), onSelect: () => set({ sessionIds: toggle(f.sessionIds, s.id) }) })),
            { kind: "divider" },
            { title: "Any session", onSelect: () => set({ sessionIds: null }) },
          ]}
        />
      ) : null}
      {cameras.length ? (
        <Chip
          label={cameraTitle}
          icon="camera"
          selected={!!f.cameraIds?.length}
          items={() => [
            ...cameras.map((c): MenuItem => ({ title: cameraDisplayName(c), checked: f.cameraIds?.includes(c.id), onSelect: () => set({ cameraIds: toggle(f.cameraIds, c.id) }) })),
            { kind: "divider" },
            { title: "Any camera", onSelect: () => set({ cameraIds: null }) },
          ]}
        />
      ) : null}
      <Chip
        label={exportedTitle}
        icon="square.and.arrow.up"
        selected={f.exportedTo != null}
        items={[
          { title: "Exported", onSelect: () => set({ exportedTo: "any" }) },
          { title: "Not exported", onSelect: () => set({ exportedTo: "never" }) },
          { title: "To Photos", onSelect: () => set({ exportedTo: "photos" }) },
          { title: "To Files", onSelect: () => set({ exportedTo: "files" }) },
          { title: "To FTP", onSelect: () => set({ exportedTo: "ftp" }) },
          { kind: "divider" },
          { title: "Either", onSelect: () => set({ exportedTo: null }) },
        ]}
      />
      {!isEmptyFilter(f) && onSaveSmart ? (
        <button className="chip" onClick={onSaveSmart}>
          <Icon name="sparkles" size={12} /> Save as smart collection
        </button>
      ) : null}
    </div>
  );
}
