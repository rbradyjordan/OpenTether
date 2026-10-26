import { useEffect, useState } from "react";
import {
  api, DESTINATION_NAMES, ROUTING_NAMES, type CaptureDestination, type FolderDestination, type RoutingTarget, type SessionTemplate, type ShootSession,
} from "../../api";
import { useApp } from "../../state/store";
import { Sheet, SheetActions } from "../../components/Sheet";
import { FormRow, FormSection, Select, TextField, Toggle } from "../../components/controls";
import { Icon } from "../../components/Icon";
import { openContextMenu } from "../../components/Menu";

type Start = { kind: "template"; id: string } | { kind: "last" } | { kind: "blank" };

function TemplateCard({ title, symbol, detail, selected, onClick, onContext }: { title: string; symbol: string; detail: string; selected: boolean; onClick: () => void; onContext?: (e: React.MouseEvent) => void }) {
  return (
    <button className={`template-card chip${selected ? " selected" : ""}`} onClick={onClick} onContextMenu={onContext} aria-pressed={selected}>
      <Icon name={symbol} size={20} style={{ color: selected ? "var(--accent)" : "var(--ink-1)" }} />
      <span className="spacer" />
      <span className="t-headline ink-0 truncate" style={{ width: "100%", flex: "none" }}>{title}</span>
      <span className="t-hud ink-1 template-detail">{detail}</span>
    </button>
  );
}

/** New session: start from a template, "Last settings" or "Blank", then adjust. */
export function NewSessionSheet({ onClose, onCreated }: { onClose: () => void; onCreated?: (s: ShootSession) => void }) {
  const looks = useApp((s) => s.looks);
  const shoot = useApp((s) => s.shoot);
  const [templates, setTemplates] = useState<SessionTemplate[]>([]);
  const [folders, setFolders] = useState<FolderDestination[]>([]);
  const [start, setStart] = useState<Start>({ kind: "last" });
  const [name, setName] = useState("");
  const [tag, setTag] = useState("");
  const [destination, setDestination] = useState<CaptureDestination>("both");
  const [jpeg, setJpeg] = useState<RoutingTarget>("photos");
  const [raw, setRaw] = useState<RoutingTarget>("files");
  const [lookId, setLookId] = useState<string | null>(null);
  const [autoExport, setAutoExport] = useState(false);
  const [liveFolder, setLiveFolder] = useState<string | null>(null);
  const cameraName = shoot?.identity?.model ?? null;

  const apply = async (s: Start, list = templates) => {
    if (s.kind === "template") {
      const t = list.find((x) => x.id === s.id);
      if (!t) return;
      setDestination(t.destination);
      setJpeg(t.routing.jpeg);
      setRaw(t.routing.raw);
      setLookId(t.look.lookId);
      setAutoExport(t.autoExportPicks);
      setLiveFolder(t.routing.liveFolderId);
      setName(await api.templateExpandName({ pattern: t.namePattern, templateName: t.name, cameraName }));
    } else if (s.kind === "last") {
      const d = await api.sessionDefaults();
      setDestination(d.destination);
      setJpeg(d.routing.jpeg);
      setRaw(d.routing.raw);
      setLookId(d.lookId);
      setAutoExport(d.routing.autoExportPicks);
      setLiveFolder(d.routing.liveFolderId);
      setName(await api.templateExpandName({ pattern: d.namePattern, templateName: "Shoot", cameraName }));
    } else {
      setDestination("both");
      setJpeg("photos");
      setRaw("files");
      setLookId(null);
      setAutoExport(false);
      setLiveFolder(null);
      setName(`Shoot ${new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short", year: "numeric" }).format(new Date())}`);
    }
  };

  useEffect(() => {
    Promise.all([api.templatesList(), api.folderDestinationsList(), api.templateSuggest({ cameraId: shoot?.identity?.id ?? null })]).then(([t, f, suggested]) => {
      setTemplates(t);
      setFolders(f);
      const s: Start = suggested ? { kind: "template", id: suggested } : { kind: "last" };
      setStart(s);
      apply(s, t);
    });
  }, []);

  const choose = (s: Start) => {
    setStart(s);
    apply(s);
  };

  const create = async () => {
    try {
      const session = await api.sessionCreate({
        draft: {
          name: name.trim() || "Untitled shoot",
          workflowTag: tag.trim() || null,
          destination,
          routing: { jpeg, raw, video: "files", autoExportPicks: autoExport, ftpDestinationId: null, liveFolderId: liveFolder },
          lookId,
          templateId: start.kind === "template" ? start.id : null,
        },
      });
      useApp.getState().toast(`Created ${session.name}`, "rectangle.stack");
      onCreated?.(session);
      onClose();
    } catch (e) {
      useApp.getState().fail(e);
    }
  };

  const destinationHelp = destination === "card"
    ? "Frames stay on the card. Open Tether still lists them when the camera announces them but downloads nothing; good for speed on slow links."
    : destination === "host" ? "Frames go straight to the Mac and are not written to the card. Fast, but a crash before download loses the frame."
    : "The camera writes the card and sends a copy. Safest choice.";

  const detail = (t: SessionTemplate) => [DESTINATION_NAMES[t.destination], t.autoExportPicks ? "auto-export picks" : null, t.tags.length ? t.tags.map((x) => `#${x}`).join(" ") : null].filter(Boolean).join(" · ");

  return (
    <Sheet title="New session" onClose={onClose} width={620} height="min(760px, calc(100vh - 48px))"
      footer={<SheetActions onCancel={onClose} primaryTitle="Create" onPrimary={create} />}>
      <div className="col" style={{ gap: 6 }}>
        <span className="t-caption">Start from</span>
        <div className="template-row">
          {templates.map((t) => (
            <TemplateCard key={t.id} title={t.name} symbol={t.symbol} detail={detail(t)} selected={start.kind === "template" && start.id === t.id}
              onClick={() => choose({ kind: "template", id: t.id })}
              onContext={(e) => openContextMenu(e, [{ title: "Edit template…", icon: "pencil", onSelect: () => useApp.getState().openModal({ kind: "templateEditor", template: t, isNew: false }) }])} />
          ))}
          <TemplateCard title="Last settings" symbol="clock.arrow.circlepath" detail="How the previous session was set up" selected={start.kind === "last"} onClick={() => choose({ kind: "last" })} />
          <TemplateCard title="Blank" symbol="square.dashed" detail="Defaults, nothing remembered" selected={start.kind === "blank"} onClick={() => choose({ kind: "blank" })} />
        </div>
      </div>
      <FormSection title="Name">
        <FormRow label="Session"><div className="form-control"><TextField value={name} onChange={setName} placeholder="Client · Location" autoFocus /></div></FormRow>
        <FormRow label="Workflow tag" hint="Optional"><div className="form-control"><TextField value={tag} onChange={setTag} placeholder="client-name" /></div></FormRow>
      </FormSection>
      <FormSection title="Where the camera writes" footer={destinationHelp}>
        <FormRow label="Capture destination">
          <div className="form-control"><Select<CaptureDestination> label="Capture destination" value={destination} onChange={setDestination}
            options={(Object.keys(DESTINATION_NAMES) as CaptureDestination[]).map((d) => ({ value: d, label: DESTINATION_NAMES[d] }))} /></div>
        </FormRow>
      </FormSection>
      <FormSection title="Hot folder" footer="Each frame and its sidecar is copied there the moment it lands: a Capture One session, a Lightroom Auto Import folder, iCloud Drive or a server.">
        <FormRow label="Copy every frame to">
          <div className="form-control"><Select<string> label="Hot folder" value={liveFolder ?? "none"} onChange={(v) => setLiveFolder(v === "none" ? null : v)}
            options={[{ value: "none", label: "Nowhere (keep on the Mac)" }, ...folders.map((f) => ({ value: f.id, label: f.name }))]} /></div>
        </FormRow>
      </FormSection>
      <FormSection title="Routing on export">
        <FormRow label="JPEG / HEIF">
          <div className="form-control"><Select<RoutingTarget> label="JPEG routing" value={jpeg} onChange={setJpeg} options={(["photos", "files", "none"] as RoutingTarget[]).map((t) => ({ value: t, label: ROUTING_NAMES[t] }))} /></div>
        </FormRow>
        <FormRow label="RAW">
          <div className="form-control"><Select<RoutingTarget> label="RAW routing" value={raw} onChange={setRaw} options={(["files", "ftp", "none"] as RoutingTarget[]).map((t) => ({ value: t, label: ROUTING_NAMES[t] }))} /></div>
        </FormRow>
        <FormRow label="Export picks automatically"><Toggle on={autoExport} onChange={setAutoExport} label="Export picks automatically" /></FormRow>
      </FormSection>
      <FormSection title="Look">
        <FormRow label="Look">
          <div className="form-control"><Select<string> label="Look" value={lookId ?? "none"} onChange={(v) => setLookId(v === "none" ? null : v)}
            options={[{ value: "none", label: "None" }, ...looks.map((l) => ({ value: l.id, label: l.name }))]} /></div>
        </FormRow>
      </FormSection>
    </Sheet>
  );
}
