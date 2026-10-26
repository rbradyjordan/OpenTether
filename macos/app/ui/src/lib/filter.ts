import type { CaptureFilter } from "../api/types";

const has = <T,>(v: T[] | null | undefined): v is T[] => Array.isArray(v) && v.length > 0;

export function isEmptyFilter(f: CaptureFilter): boolean {
  return f.minRating == null && f.maxRating == null && !has(f.flags) && !has(f.colors) && !has(f.kinds) && !has(f.sessionIds)
    && !has(f.cameraIds) && !has(f.tagsAll) && !has(f.tagsAny) && f.dateRange == null && !(f.text ?? "").trim() && f.hasLook == null
    && f.exportedTo == null;
}

const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

/** Human summary for chips: "4★+ · Picks · red, blue · #hero". */
export function filterSummary(f: CaptureFilter): string {
  const parts: string[] = [];
  if (f.minRating != null && f.minRating > 0) parts.push(`${f.minRating}★+`);
  if (f.maxRating === 0) parts.push("unrated");
  if (has(f.flags)) parts.push([...f.flags].sort().map(cap).join("/"));
  if (has(f.colors)) parts.push([...f.colors].sort().join(", "));
  if (has(f.kinds)) parts.push([...f.kinds].map((k) => k.toUpperCase()).sort().join("/"));
  if (has(f.tagsAll)) parts.push([...f.tagsAll].sort().map((t) => `#${t}`).join(" "));
  if (has(f.tagsAny)) parts.push("any of " + [...f.tagsAny].sort().map((t) => `#${t}`).join(" "));
  switch (f.dateRange?.kind) {
    case "today": parts.push("today"); break;
    case "last7Days": parts.push("last 7 days"); break;
    case "last30Days": parts.push("last 30 days"); break;
    case "between": parts.push("date range"); break;
    default: break;
  }
  if (has(f.sessionIds)) parts.push(f.sessionIds.length === 1 ? "1 session" : `${f.sessionIds.length} sessions`);
  if (has(f.cameraIds)) parts.push(f.cameraIds.length === 1 ? "1 camera" : `${f.cameraIds.length} cameras`);
  if ((f.text ?? "").trim()) parts.push(`“${f.text}”`);
  if (f.exportedTo) parts.push(f.exportedTo === "never" ? "not exported" : `exported${f.exportedTo === "any" ? "" : ` to ${f.exportedTo}`}`);
  return parts.length === 0 ? "Everything" : parts.join(" · ");
}

export function normalizeTag(s: string): string {
  return s.trim().toLowerCase().replace(/#/g, "").replace(/\s+/g, "-");
}

/** Merges the grid's chip filter with the search field (text). */
export function withSearch(f: CaptureFilter, text: string): CaptureFilter {
  const t = text.trim();
  return t ? { ...f, text: t } : f;
}
