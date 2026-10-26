import { useEffect, useState } from "react";
import { api, cameraDisplayName, destinationLabel, type ExportMemory, type SessionSummary } from "../../api";
import { filterSummary } from "../../lib/filter";
import { useApp } from "../../state/store";
import { Screen, useStack } from "../routes";
import { EmptyState, SectionCard, TonePill } from "../../components/common";
import { Icon } from "../../components/Icon";
import { CaptureImage } from "../../components/media";
import { openContextMenu } from "../../components/Menu";
import { ResumeBanner } from "../connect/ConnectHub";
import { formatDateTime, plural } from "../../lib/format";

function transportIcon(s: SessionSummary["session"]): string {
  switch (s.transport) {
    case "usb": return "cable.connector";
    case "ptpip": case "ricohHTTP": case "http": return "wifi";
    case "ftpPush": return "arrow.down.doc";
    default: return "rectangle.stack";
  }
}

/** Large card: the three newest frames, name, meta line and counts. */
function SessionCard({ summary, live, onOpen }: { summary: SessionSummary; live: boolean; onOpen: () => void }) {
  const s = summary.session;
  const st = useApp.getState;
  const meta = [formatDateTime(s.createdAt), s.camera ? cameraDisplayName(s.camera) : null, s.status !== "ended" ? s.status[0].toUpperCase() + s.status.slice(1) : null, s.workflowTag ? `#${s.workflowTag}` : null]
    .filter(Boolean).join(" · ");
  return (
    <button
      className="session-card card"
      onClick={onOpen}
      onContextMenu={(e) => openContextMenu(e, [
        { title: "Open in Library", icon: "photo.on.rectangle", onSelect: () => st().selectSource({ kind: "session", id: s.id }) },
        { title: "Rename…", icon: "pencil", onSelect: () => st().openModal({ kind: "rename", title: "Rename session", value: s.name, onSave: (name) => api.sessionRename({ id: s.id, name }).catch(st().fail) }) },
        { kind: "divider" },
        { title: "Delete session…", icon: "trash", destructive: true, onSelect: () => st().openModal({
          kind: "confirm", title: "Delete this session?", message: "Frames, ratings and exports in this session are removed from the Mac.", confirmTitle: "Delete", destructive: true, cancelTitle: "Keep",
          onConfirm: () => api.sessionDelete({ id: s.id }).catch(st().fail),
        }) },
      ])}
      aria-label={`${s.name}, ${summary.counts.total} frames, ${summary.counts.picks} picks, ${s.status}`}
    >
      <div className="session-strip">
        {[0, 1, 2].map((i) => (
          <div key={i} className="session-strip-cell">
            {summary.recent[i] ? <CaptureImage item={summary.recent[i]} variant="thumb" /> : i === 0 && !summary.recent.length ? <Icon name="photo" size={20} className="ink-2" /> : null}
          </div>
        ))}
      </div>
      <div className="row" style={{ padding: "12px 16px 14px", alignItems: "flex-start" }}>
        <div className="col fill" style={{ gap: 3 }}>
          <div className="row">
            <Icon name={transportIcon(s)} size={13} style={{ color: live ? "var(--accent)" : "var(--ink-2)" }} />
            <span className="t-headline truncate">{s.name}</span>
            {live ? <TonePill text="Live" tone="ok" /> : null}
          </div>
          <span className="t-hud ink-1 truncate">{meta}</span>
        </div>
        <div className="col" style={{ alignItems: "flex-end", gap: 2 }}>
          <span className="t-exposure">{summary.counts.total}</span>
          <span className="row t-hud" style={{ gap: 8 }}>
            {summary.counts.picks ? <span className="row c-ok" style={{ gap: 3 }}><Icon name="flag.fill" size={10} />{summary.counts.picks}</span> : null}
            {summary.counts.rejects ? <span className="row c-danger" style={{ gap: 3 }}><Icon name="xmark.circle.fill" size={10} />{summary.counts.rejects}</span> : null}
          </span>
        </div>
      </div>
    </button>
  );
}

/** "Continue where you left off": the last library view, plus "Export like last time". */
function ContinueCard() {
  const sources = useApp((s) => s.sources);
  const [key, setKey] = useState<string | null>(null);
  const [memory, setMemory] = useState<ExportMemory | null>(null);
  const [summary, setSummary] = useState("");
  useEffect(() => {
    api.lastSourceGet().then(async (k) => {
      setKey(k);
      if (k) {
        const v = await api.viewStateGet({ key: k });
        if (v) setSummary(filterSummary(v.filter));
      }
    });
    api.exportMemoryGet().then(setMemory);
  }, []);
  if (!key || !sources) return null;
  const [kind, ...rest] = key.split(":");
  const id = rest.join(":");
  const name = kind === "collection" ? [...sources.builtIns, ...sources.manual, ...sources.smart].find((c) => c.id === id)?.name
    : kind === "session" ? sources.sessions.find((s) => s.id === id)?.name
    : sources.cameras.find((c) => c.id === id)?.model;
  const count = sources.counts[key] ?? 0;
  if (!name || !count) return null;
  const st = useApp.getState;
  const open = () => st().selectSource({ kind: kind as "collection" | "session" | "camera", id });
  return (
    <SectionCard title="Continue where you left off" icon="arrow.uturn.forward">
      <button className="list-row interactive" onClick={open}>
        <div className="col fill" style={{ gap: 0 }}>
          <span className="t-headline">{name}</span>
          <span className="t-hud ink-1">{plural(count, "photo")} · {summary || "Everything"}</span>
        </div>
        <Icon name="chevron.right" size={13} className="ink-2" />
      </button>
      {memory ? (
        <button className="btn secondary small" style={{ alignSelf: "flex-start" }} onClick={async () => {
          await open();
          const ids = useApp.getState().library.items.map((i) => i.id);
          api.exportAgain({ captureIds: ids }).catch(st().fail);
        }}>
          <Icon name="arrow.uturn.up" size={13} /> Export like last time · {destinationLabel(memory.destination)}
        </button>
      ) : null}
    </SectionCard>
  );
}

export function SessionsHome() {
  const sessions = useApp((s) => s.sessions);
  const shoot = useApp((s) => s.shoot);
  const { push } = useStack();
  useEffect(() => {
    useApp.getState().refreshSessions();
  }, []);
  const interrupted = sessions.filter((s) => s.session.status === "interrupted" && s.session.id !== shoot?.session.id);
  return (
    <Screen title="Sessions" trailing={<button className="btn secondary small" onClick={() => useApp.getState().openModal({ kind: "newSession" })}><Icon name="plus" size={13} /> New session</button>}>
      <div className="stack" style={{ maxWidth: 1100, margin: "0 auto" }}>
        {interrupted.map((s) => <ResumeBanner key={s.session.id} summary={s} />)}
        <ContinueCard />
        {!sessions.length ? (
          <EmptyState icon="rectangle.stack" title="No sessions yet" message="A session groups one shoot's frames, ratings and exports." action="New session" onAction={() => useApp.getState().openModal({ kind: "newSession" })} />
        ) : null}
        <div className="session-grid">
          {sessions.map((s, i) => {
            const live = shoot?.session.id === s.session.id;
            return (
              <div key={s.session.id} className="arrive" style={{ animationDelay: `${Math.min(i, 8) * 40}ms` }}>
                <SessionCard summary={s} live={live} onOpen={() => (live ? useApp.getState().setShowShoot(true) : push({ kind: "sessionDetail", id: s.session.id }))} />
              </div>
            );
          })}
        </div>
      </div>
    </Screen>
  );
}
