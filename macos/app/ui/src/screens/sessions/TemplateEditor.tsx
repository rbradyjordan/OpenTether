import { useEffect, useState } from "react";
import { api, DESTINATION_NAMES, ROUTING_NAMES, type CaptureDestination, type RoutingTarget, type SessionTemplate } from "../../api";
import { useApp } from "../../state/store";
import { Sheet, SheetActions } from "../../components/Sheet";
import { FormRow, FormSection, Select, TextField, Toggle } from "../../components/controls";
import { SymbolPicker } from "../library/CollectionEditor";
import { TagEditor } from "../library/TagEditor";

const TOKENS = ["{date}", "{name}", "{camera}", "{n}", "{weekday}"];

/** Create or edit a session template: name, symbol, capture, routing, look, name pattern with preview, tags. */
export function TemplateEditor({ template: initial, isNew, onClose }: { template: SessionTemplate; isNew: boolean; onClose: () => void }) {
  const looks = useApp((s) => s.looks);
  const sources = useApp((s) => s.sources);
  const manual = sources?.manual ?? [];
  const cameraName = useApp((s) => s.shoot?.identity?.model ?? null);
  const [t, setT] = useState(initial);
  const [example, setExample] = useState("");
  const set = (patch: Partial<SessionTemplate>) => setT((x) => ({ ...x, ...patch }));
  useEffect(() => {
    api.templateExpandName({ pattern: t.namePattern, templateName: t.name || "Template", cameraName }).then(setExample);
  }, [t.namePattern, t.name, cameraName]);

  const save = async () => {
    try {
      await api.templateSave({ template: t });
      onClose();
    } catch (e) {
      useApp.getState().fail(e);
    }
  };

  return (
    <Sheet title={isNew ? "Save as template" : "Edit template"} onClose={onClose} width={600} height="min(780px, calc(100vh - 48px))"
      footer={<SheetActions
        leading={!isNew ? <button className="btn plain danger" onClick={() => api.templateDelete({ id: t.id }).then(onClose)}>Delete template</button> : undefined}
        onCancel={onClose} primaryTitle="Save" onPrimary={save} primaryDisabled={!t.name.trim()} />}>
      <FormSection title="Template">
        <FormRow label="Name"><div className="form-control"><TextField value={t.name} onChange={(name) => set({ name })} placeholder="Headshots, Lookbook…" autoFocus /></div></FormRow>
        <div style={{ padding: "8px 0" }}><SymbolPicker selected={t.symbol} onPick={(symbol) => set({ symbol })} /></div>
      </FormSection>
      <FormSection title="Session name" footer={`Tokens: ${TOKENS.join(" ")}`}>
        <FormRow label="Pattern"><div className="form-control"><TextField mono value={t.namePattern} onChange={(namePattern) => set({ namePattern })} /></div></FormRow>
        <FormRow label="Example"><span className="t-callout ink-0">{example}</span></FormRow>
      </FormSection>
      <FormSection title="Capture">
        <FormRow label="Camera writes to">
          <div className="form-control"><Select<CaptureDestination> label="Camera writes to" value={t.destination} onChange={(destination) => set({ destination })}
            options={(Object.keys(DESTINATION_NAMES) as CaptureDestination[]).map((d) => ({ value: d, label: DESTINATION_NAMES[d] }))} /></div>
        </FormRow>
        <FormRow label="Show newest capture"><Toggle on={t.showNewestCapture} onChange={(showNewestCapture) => set({ showNewestCapture })} label="Show newest capture" /></FormRow>
        <FormRow label="Look">
          <div className="form-control"><Select<string> label="Look" value={t.look.lookId ?? "none"} onChange={(v) => set({ look: { ...t.look, lookId: v === "none" ? null : v } })}
            options={[{ value: "none", label: "None" }, ...looks.map((l) => ({ value: l.id, label: l.name }))]} /></div>
        </FormRow>
      </FormSection>
      <FormSection title="Routing on export">
        <FormRow label="JPEG / HEIF">
          <div className="form-control"><Select<RoutingTarget> label="JPEG routing" value={t.routing.jpeg} onChange={(jpeg) => set({ routing: { ...t.routing, jpeg } })}
            options={(["photos", "files", "none"] as RoutingTarget[]).map((x) => ({ value: x, label: ROUTING_NAMES[x] }))} /></div>
        </FormRow>
        <FormRow label="RAW">
          <div className="form-control"><Select<RoutingTarget> label="RAW routing" value={t.routing.raw} onChange={(raw) => set({ routing: { ...t.routing, raw } })}
            options={(["files", "ftp", "none"] as RoutingTarget[]).map((x) => ({ value: x, label: ROUTING_NAMES[x] }))} /></div>
        </FormRow>
        <FormRow label="Export picks automatically"><Toggle on={t.autoExportPicks} onChange={(autoExportPicks) => set({ autoExportPicks, routing: { ...t.routing, autoExportPicks } })} label="Export picks automatically" /></FormRow>
      </FormSection>
      <FormSection title="Every frame gets">
        <div style={{ padding: "8px 0" }}>
          <TagEditor tags={t.tags} onAdd={(x) => set({ tags: t.tags.includes(x) ? t.tags : [...t.tags, x] })} onRemove={(x) => set({ tags: t.tags.filter((y) => y !== x) })} />
        </div>
        <FormRow label="Added to collection">
          <div className="form-control"><Select<string> label="Added to collection" value={t.addToCollectionId ?? "none"} onChange={(v) => set({ addToCollectionId: v === "none" ? null : v })}
            options={[{ value: "none", label: "None" }, ...manual.map((c) => ({ value: c.id, label: c.name }))]} /></div>
        </FormRow>
      </FormSection>
    </Sheet>
  );
}
