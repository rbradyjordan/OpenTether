import { useState } from "react";
import { api, type ExportDestination, type ExportItemState, type ExportJob, type ExportJobStatus } from "../../api";
import { useApp } from "../../state/store";
import { Screen } from "../routes";
import { Sheet } from "../../components/Sheet";
import { EmptyState, ProgressBar } from "../../components/common";
import { Icon } from "../../components/Icon";
import { formatDateTime, plural } from "../../lib/format";

const icon = (d: ExportDestination) => (d.kind === "photos" ? "photo.on.rectangle" : d.kind === "ftp" ? "server.rack" : "folder");

function statusText(s: ExportJobStatus): string {
  switch (s.kind) {
    case "queued": return "Queued";
    case "running": return "Running";
    case "paused": return "Paused";
    case "completed": return "Done";
    case "failed": return s.message;
  }
}

function statusColor(s: ExportJobStatus): string {
  return s.kind === "completed" ? "var(--ok)" : s.kind === "failed" ? "var(--danger)" : s.kind === "running" ? "var(--accent)" : "var(--ink-1)";
}

function itemState(s: ExportItemState): string {
  switch (s.kind) {
    case "pending": return "waiting";
    case "uploading": return `${Math.round(s.progress * 100)}%`;
    case "done": return "done";
    case "skipped": return `skipped: ${s.reason}`;
    case "failed": return `failed: ${s.reason}`;
  }
}

function JobRow({ job }: { job: ExportJob }) {
  const [open, setOpen] = useState(false);
  const sessions = useApp((s) => s.sessions);
  const done = job.items.filter((i) => i.state.kind === "done" || i.state.kind === "skipped").length;
  const failed = job.items.filter((i) => i.state.kind === "failed").length;
  const session = sessions.find((s) => s.session.id === job.sessionId)?.session;
  return (
    <div className="card col" style={{ gap: 8 }}>
      <div className="row">
        <Icon name={icon(job.destination)} size={16} className="ink-1" />
        <span className="t-headline truncate">{job.destinationName}</span>
        <span className="t-hud ink-2 truncate">{session?.name}</span>
        <span className="spacer" />
        <span className="t-hud" style={{ color: statusColor(job.status) }}>{statusText(job.status)}</span>
      </div>
      <ProgressBar value={job.progress} tone={job.status.kind === "failed" ? "danger" : job.status.kind === "completed" ? "ok" : "accent"} />
      <div className="row t-hud ink-1">
        <span>{done} of {plural(job.items.length, "file")} done · {formatDateTime(job.createdAt)}</span>
        <span className="spacer" />
        <button className="btn plain small" onClick={() => setOpen((o) => !o)}>
          Frames <Icon name={open ? "chevron.up" : "chevron.down"} size={11} />
        </button>
      </div>
      {open ? (
        <div className="col" style={{ gap: 2, maxHeight: 220, overflow: "auto" }}>
          {job.items.map((i) => (
            <div key={i.id} className="row t-hud">
              <span className="truncate fill ink-0">{i.deliveredPath || i.filename}</span>
              <span style={{ color: i.state.kind === "failed" ? "var(--danger)" : "var(--ink-2)" }}>{itemState(i.state)}</span>
            </div>
          ))}
        </div>
      ) : null}
      {failed || job.status.kind === "completed" ? (
        <div className="row">
          {failed || job.status.kind === "failed" ? <button className="btn secondary small" onClick={() => api.exportRetry({ jobId: job.id })}>Retry failed</button> : null}
          {job.status.kind === "completed" && job.destination.kind !== "photos" ? (
            <button className="btn secondary small" onClick={() => api.exportReveal({ jobId: job.id })}><Icon name="folder" size={13} /> Show in Finder</button>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

function JobsList({ sessionId }: { sessionId: string | null }) {
  const jobs = useApp((s) => s.jobs).filter((j) => !sessionId || j.sessionId === sessionId);
  if (!jobs.length) return <EmptyState icon="arrow.up.doc" title="No exports yet" message="Exports show up here with per-frame progress." />;
  return (
    <div className="stack">
      {jobs.map((j) => <JobRow key={j.id} job={j} />)}
    </div>
  );
}

function PauseButton() {
  const [paused, setPaused] = useState(false);
  return (
    <button className="btn secondary small" onClick={() => {
      setPaused(!paused);
      (paused ? api.exportResumeAll() : api.exportPauseAll()).catch(useApp.getState().fail);
    }}>
      <Icon name={paused ? "play.fill" : "pause.fill"} size={12} /> {paused ? "Resume all" : "Pause all"}
    </button>
  );
}

export function ExportProgress({ sessionId }: { sessionId: string | null }) {
  return (
    <Screen title="Exports" trailing={<PauseButton />} readable>
      <JobsList sessionId={sessionId} />
    </Screen>
  );
}

export function ExportProgressSheet({ sessionId, onClose }: { sessionId: string | null; onClose: () => void }) {
  return (
    <Sheet title="Exports" onClose={onClose} width={620} height="min(640px, calc(100vh - 48px))" headerTrailing={<PauseButton />}>
      <JobsList sessionId={sessionId} />
    </Sheet>
  );
}
