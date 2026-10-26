import { useEffect, useRef, useState } from "react";
import { api, type MetadataProfile } from "../../api";
import { useApp, inspectedItem } from "../../state/store";
import { Screen } from "../routes";
import { FormRow, FormSection, TextField, Toggle } from "../../components/controls";

/** Creator, copyright, captions and where XMP goes, with a live packet preview for the focused frame. */
export function MetadataSettings() {
  const [p, setP] = useState<MetadataProfile | null>(null);
  const [preview, setPreview] = useState<{ filename: string | null; packet: string | null }>({ filename: null, packet: null });
  const focused = useApp((s) => inspectedItem(s.library)?.id ?? null);
  const saveTimer = useRef<number | null>(null);

  useEffect(() => {
    api.metadataProfileGet().then(setP);
  }, []);
  useEffect(() => {
    if (!p) return;
    if (saveTimer.current != null) clearTimeout(saveTimer.current);
    saveTimer.current = window.setTimeout(() => {
      api.metadataProfileSet({ profile: p }).then(() => api.xmpPreview({ captureId: focused })).then(setPreview);
    }, 250);
  }, [p, focused]);

  if (!p) return <Screen title="Metadata"><div /></Screen>;
  const text = (k: keyof MetadataProfile) => (p[k] as string | null) ?? "";
  const setText = (k: keyof MetadataProfile) => (v: string) => setP({ ...p, [k]: v ? v : null });
  const year = new Date().getFullYear();
  return (
    <Screen title="Metadata" readable>
      <div className="stack" style={{ gap: 20 }}>
        <FormSection title="Who">
          <FormRow label="Creator"><div className="form-control"><TextField value={text("creator")} onChange={setText("creator")} placeholder="Your name" /></div></FormRow>
          <FormRow label="Copyright" hint="{year} allowed"><div className="form-control"><TextField value={text("copyright")} onChange={setText("copyright")} placeholder="© {year} Your name" /></div></FormRow>
          <FormRow label="Resolves to"><span className="t-callout ink-0">{p.copyright ? p.copyright.replace("{year}", String(year)) : "—"}</span></FormRow>
        </FormSection>
        <FormSection title="Keywords and captions" footer="Caption tokens: {session} {date} {camera} {client} {orig} {rating}. Keywords become Lightroom hierarchical subjects under the root.">
          <FormRow label="Caption template"><div className="form-control"><TextField value={text("captionTemplate")} onChange={setText("captionTemplate")} placeholder="{session} – {date}" /></div></FormRow>
          <FormRow label="Hierarchical keyword root"><div className="form-control"><TextField value={text("hierarchicalRoot")} onChange={setText("hierarchicalRoot")} placeholder="Tether" /></div></FormRow>
          <FormRow label="Session name as keyword"><Toggle on={p.sessionAsKeyword} onChange={(v) => setP({ ...p, sessionAsKeyword: v })} label="Session name as keyword" /></FormRow>
        </FormSection>
        <FormSection title="Where metadata goes">
          <FormRow label="Embed XMP in exported JPEGs"><Toggle on={p.embedInJpeg} onChange={(v) => setP({ ...p, embedInJpeg: v })} label="Embed XMP in exported JPEGs" /></FormRow>
          <FormRow label="Write .xmp sidecars for RAW"><Toggle on={p.writeSidecarsForRaw} onChange={(v) => setP({ ...p, writeSidecarsForRaw: v })} label="Write .xmp sidecars for RAW" /></FormRow>
          <FormRow label="Write .xmp sidecars for JPEG"><Toggle on={p.writeSidecarsForJpeg} onChange={(v) => setP({ ...p, writeSidecarsForJpeg: v })} label="Write .xmp sidecars for JPEG" /></FormRow>
          <FormRow label="Read XMP from incoming files"><Toggle on={p.readIncomingXmp} onChange={(v) => setP({ ...p, readIncomingXmp: v })} label="Read XMP from incoming files" /></FormRow>
        </FormSection>
        <FormSection title={preview.filename ? `XMP preview · ${preview.filename}` : "XMP preview"}>
          <pre className="xmp-preview selectable">{preview.packet ?? "Shoot or import a frame to preview its XMP."}</pre>
        </FormSection>
      </div>
    </Screen>
  );
}
