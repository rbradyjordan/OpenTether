import { useEffect, useMemo, useState } from "react";
import {
  api, destinationKey, errorMessage, FOLDER_LAYOUT_NAMES, NAMING_PRESETS, RAW_OUTPUT_NAMES,
  type ExportDestination, type ExportOptions, type ExportPlan, type ExportRequest, type ExportScope, type FolderDestination,
  type FolderLayout, type FtpDestination, type RawOutput,
} from "../../api";
import { useApp } from "../../state/store";
import type { ExportContext } from "../../state/types";
import { Sheet, SheetActions } from "../../components/Sheet";
import { FormRow, FormSection, Segmented, Select, Slider, TextField, Toggle, type Option } from "../../components/controls";
import { Icon } from "../../components/Icon";
import { plural } from "../../lib/format";

type ScopeId = "all" | "picks" | "rated" | "selected" | "selection" | "collection";

const DEFAULT_OPTIONS: ExportOptions = {
  applyLook: true, maxLongEdge: null, jpegQuality: 0.92, includeRaw: false, namingPattern: "{orig}", layout: "flat",
  embedMetadata: true, writeSidecars: true, writeManifest: false, rawOutput: "original",
};

function folderKindNote(f: FolderDestination): string | null {
  if (f.kind === "captureOneSession") return "Capture One session: photos go into Capture, Selects and Trash.";
  if (f.kind === "lightroomAutoImport") return "Lightroom Auto Import: one flat folder, sidecars written first.";
  return null;
}

/** Export a session, a library selection or a collection; starts from (and remembers) the last export's settings. */
export function ExportSheet({ ctx, onClose }: { ctx: ExportContext; onClose: () => void }) {
  const fromLibrary = ctx.sessionId == null;
  const presets = useMemo(() => {
    const out: Option<ScopeId>[] = [{ value: "all", label: "All" }, { value: "picks", label: "Picks" }, { value: "rated", label: "Rated ≥" }];
    if (fromLibrary) {
      if (ctx.selectionIds.length) out.push({ value: "selection", label: `Selection (${ctx.selectionIds.length})` });
      if (ctx.collection) out.push({ value: "collection", label: "This collection" });
    } else if (ctx.selectedId) {
      out.push({ value: "selected", label: "Selected" });
    }
    return out;
  }, [fromLibrary, ctx]);

  const [scope, setScope] = useState<ScopeId>(ctx.selectionIds.length > 1 ? "selection" : "all");
  const [minRating, setMinRating] = useState(3);
  const [destination, setDestination] = useState<ExportDestination>({ kind: "photos" });
  const [options, setOptions] = useState<ExportOptions>(DEFAULT_OPTIONS);
  const [resize, setResize] = useState(false);
  const [longEdge, setLongEdge] = useState(2048);
  const [ftp, setFtp] = useState<FtpDestination[]>([]);
  const [folders, setFolders] = useState<FolderDestination[]>([]);
  const [plan, setPlan] = useState<ExportPlan | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const lookNeutral = ctx.look != null && !ctx.look.lookId;

  useEffect(() => {
    Promise.all([api.exportMemoryGet(), api.ftpDestinationsList(), api.folderDestinationsList()]).then(([m, f, d]) => {
      setFtp(f);
      setFolders(d);
      setDestination(m.destination);
      setOptions({ ...m.options, applyLook: lookNeutral ? false : m.options.applyLook });
      setResize(m.options.maxLongEdge != null);
      setLongEdge(m.options.maxLongEdge ?? 2048);
      const remembered: ScopeId | null = m.scope.startsWith("rated") ? "rated" : (m.scope as ScopeId);
      if (m.scope.startsWith("rated")) setMinRating(Number(m.scope.slice(5)) || 3);
      if (ctx.selectionIds.length > 1 && fromLibrary) setScope("selection");
      else if (remembered && presets.some((p) => p.value === remembered)) setScope(remembered);
    }).catch((e) => setError(errorMessage(e)));
  }, []);

  const exportScope: ExportScope = scope === "picks" ? { kind: "picks" }
    : scope === "rated" ? { kind: "rated", min: minRating }
    : scope === "selected" && ctx.selectedId ? { kind: "selected", captureId: ctx.selectedId }
    : scope === "selection" ? { kind: "selection", ids: ctx.selectionIds }
    : scope === "collection" && ctx.collection ? { kind: "collection", collectionId: ctx.collection.id }
    : { kind: "all" };
  const effective: ExportOptions = { ...options, maxLongEdge: resize ? longEdge : null };
  const request: ExportRequest = { sessionId: ctx.sessionId, captureIds: ctx.captureIds, scope: exportScope, destination, options: effective, look: ctx.look };
  const planKey = JSON.stringify(request);

  useEffect(() => {
    let live = true;
    api.exportPlan({ request }).then((p) => live && setPlan(p)).catch(() => live && setPlan(null));
    return () => {
      live = false;
    };
  }, [planKey]);

  const set = (patch: Partial<ExportOptions>) => setOptions((o) => ({ ...o, ...patch }));
  const total = (plan?.photoCount ?? 0) + (plan?.rawCount ?? 0);
  const summary = !plan || total === 0 ? "Nothing selected"
    : [plan.photoCount ? plural(plan.photoCount, "photo") : null, plan.rawCount ? `${plan.rawCount} ${options.rawOutput === "original" ? "RAW" : `RAW → ${RAW_OUTPUT_NAMES[options.rawOutput]}`}` : null].filter(Boolean).join(" · ");

  const destOptions: Option<string>[] = [
    { value: "photos", label: "Photos" },
    { value: "files", label: "Pictures › Open Tether › Exports" },
    ...folders.map((f) => ({ value: `folder:${f.id}`, label: `Folder · ${f.name}` })),
    ...ftp.map((d) => ({ value: `ftp:${d.id}`, label: `FTP · ${d.name}` })),
  ];
  const chosenFolder = destination.kind === "folder" ? folders.find((f) => f.id === destination.destinationId) : undefined;

  const pickDestination = (key: string) => {
    if (key === "photos" || key === "files") return setDestination({ kind: key });
    const [kind, id] = key.split(":");
    if (kind === "ftp") setDestination({ kind: "ftp", destinationId: id });
    if (kind === "folder") {
      setDestination({ kind: "folder", destinationId: id });
      const f = folders.find((x) => x.id === id);
      if (f?.kind === "captureOneSession") set({ layout: "captureOneSessionRoot" });
      else if (f?.kind === "lightroomAutoImport") set({ layout: "flat" });
    }
  };

  const enqueue = async () => {
    setBusy(true);
    try {
      const jobs = await api.exportEnqueue({ request });
      const n = jobs.reduce((a, j) => a + j.items.filter((i) => !i.isCompanion).length, 0);
      useApp.getState().toast(`Exporting ${plural(n, "frame")} to ${jobs[0]?.destinationName ?? "destination"}`, "arrow.up.doc");
      onClose();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Sheet
      title={ctx.title ?? "Export"}
      onClose={onClose}
      width={600}
      height="min(780px, calc(100vh - 48px))"
      footer={
        <SheetActions
          leading={<span className="t-hud ink-1">{summary}</span>}
          onCancel={onClose}
          primaryTitle={busy ? "Queuing…" : total ? `Export ${total}` : "Nothing to export"}
          onPrimary={enqueue}
          primaryDisabled={!total || busy}
        />
      }
    >
      <FormSection title="What">
        <FormRow label={<Segmented value={scope} options={presets} onChange={setScope} />}>
          {scope === "rated" ? (
            <div className="row" style={{ gap: 4 }}>
              <button className="icon-btn" aria-label="Lower minimum rating" disabled={minRating <= 1} onClick={() => setMinRating((n) => n - 1)}><Icon name="minus" size={14} /></button>
              <span className="t-exposure" style={{ minWidth: 34, textAlign: "center" }}>{minRating}<span style={{ color: "var(--pick)", fontSize: 13 }}>★</span></span>
              <button className="icon-btn" aria-label="Raise minimum rating" disabled={minRating >= 5} onClick={() => setMinRating((n) => n + 1)}><Icon name="plus" size={14} /></button>
            </div>
          ) : null}
        </FormRow>
      </FormSection>

      <FormSection title="Where">
        <FormRow label="Destination">
          <div className="form-control"><Select label="Destination" value={destinationKey(destination)} options={destOptions} onChange={pickDestination} /></div>
        </FormRow>
        {chosenFolder ? (
          <FormRow label="Location" hint={folderKindNote(chosenFolder) ?? undefined}>
            <span className="t-hud ink-1 truncate" style={{ maxWidth: 280 }}>{chosenFolder.path}</span>
          </FormRow>
        ) : null}
        <FormRow label="">
          <div className="row">
            <button className="btn plain small" onClick={async () => {
              const [path] = await api.dialogPick({ kind: "folder", multiple: false });
              if (!path) return;
              const f = await api.folderDestinationAdd({ path });
              setFolders(await api.folderDestinationsList());
              pickDestination(`folder:${f.id}`);
            }}>
              <Icon name="folder.badge.plus" size={14} /> Add a folder…
            </button>
            <button className="btn plain small" onClick={() => {
              const s = useApp.getState();
              s.openModal({ kind: "settings" });
              s.popTo("settings", 0);
              s.push("settings", { kind: "ftpDestinations" });
            }}>
              <Icon name="server.rack" size={14} /> FTP destinations…
            </button>
          </div>
        </FormRow>
      </FormSection>

      <FormSection title="Options">
        <FormRow label="Apply look" hint={lookNeutral ? "No look on this session" : undefined}><Toggle on={options.applyLook && !lookNeutral} disabled={lookNeutral} onChange={(v) => set({ applyLook: v })} label="Apply look" /></FormRow>
        <FormRow label="Include RAW files"><Toggle on={options.includeRaw} onChange={(v) => set({ includeRaw: v })} label="Include RAW files" /></FormRow>
        {options.includeRaw ? (
          <FormRow label="RAW as">
            <div className="form-control">
              <Select label="RAW as" value={options.rawOutput} options={(Object.keys(RAW_OUTPUT_NAMES) as RawOutput[]).map((r) => ({ value: r, label: RAW_OUTPUT_NAMES[r] }))} onChange={(rawOutput) => set({ rawOutput })} />
            </div>
          </FormRow>
        ) : null}
        <FormRow label="Resize"><Toggle on={resize} onChange={setResize} label="Resize" /></FormRow>
        {resize ? (
          <FormRow label="Long edge">
            <div className="form-control">
              <Select label="Long edge" value={longEdge} options={[1024, 2048, 3000, 4096].map((n) => ({ value: n, label: `${n} px` }))} onChange={setLongEdge} />
            </div>
          </FormRow>
        ) : null}
        <FormRow label={`JPEG quality ${Math.round(options.jpegQuality * 100)}`}>
          <div className="form-control"><Slider label="JPEG quality" value={options.jpegQuality} min={0.5} max={1} step={0.02} onChange={(v) => set({ jpegQuality: v })} /></div>
        </FormRow>
      </FormSection>

      <FormSection
        title="Files"
        footer={
          <div className="col" style={{ gap: 2 }}>
            <span>Tokens: {"{orig} {session} {date} {seq:4} {camera} {client} {rating} {label} {pick}"}</span>
            {(plan?.previewPaths ?? []).map((p) => <span key={p} className="t-mono ink-0">{p}</span>)}
          </div>
        }
      >
        <FormRow label="Naming">
          <div className="form-control">
            <Select
              label="Naming preset"
              value={NAMING_PRESETS.includes(options.namingPattern) ? options.namingPattern : "custom"}
              options={[...NAMING_PRESETS.map((p) => ({ value: p, label: p })), ...(NAMING_PRESETS.includes(options.namingPattern) ? [] : [{ value: "custom", label: "Custom" }])]}
              onChange={(v) => v !== "custom" && set({ namingPattern: v })}
            />
          </div>
        </FormRow>
        <FormRow label="Pattern">
          <div className="form-control"><TextField mono value={options.namingPattern} onChange={(namingPattern) => set({ namingPattern })} label="Naming pattern" /></div>
        </FormRow>
        <FormRow label="Folders">
          <div className="form-control">
            <Select label="Folder layout" value={options.layout} options={(Object.keys(FOLDER_LAYOUT_NAMES) as FolderLayout[]).map((l) => ({ value: l, label: FOLDER_LAYOUT_NAMES[l] }))} onChange={(layout) => set({ layout })} />
          </div>
        </FormRow>
        <FormRow label="Embed XMP in JPEGs"><Toggle on={options.embedMetadata} onChange={(v) => set({ embedMetadata: v })} label="Embed XMP in JPEGs" /></FormRow>
        <FormRow label="Write .xmp sidecars"><Toggle on={options.writeSidecars} onChange={(v) => set({ writeSidecars: v })} label="Write .xmp sidecars" /></FormRow>
        <FormRow label="Write manifest (JSON + CSV)"><Toggle on={options.writeManifest} onChange={(v) => set({ writeManifest: v })} label="Write manifest" /></FormRow>
      </FormSection>
      {error ? <div className="t-callout c-danger">{error}</div> : null}
    </Sheet>
  );
}
