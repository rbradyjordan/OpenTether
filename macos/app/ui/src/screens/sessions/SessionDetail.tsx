import { useEffect, useState } from "react";
import { api, cameraDisplayName, isReady, type SessionSummary } from "../../api";
import { useApp } from "../../state/store";
import { Screen, useStack } from "../routes";
import { EmptyState, SectionCard } from "../../components/common";
import { Icon } from "../../components/Icon";
import { CaptureImage } from "../../components/media";
import { MenuButton, openContextMenu, commandItems } from "../../components/Menu";
import { RatingDots } from "../../components/review";
import { commandsFor, runCommand, openExport } from "../../commands/dispatcher";
import { importFiles } from "../library/actions";
import { formatDateTime, plural } from "../../lib/format";

/** An ended (or paused) session: grid, loupe, export, resume. */
export function SessionDetail({ id }: { id: string }) {
  const { push, pop } = useStack();
  const detail = useApp((s) => s.sessionDetail);
  const [summary, setSummary] = useState<SessionSummary | null>(null);
  const [missing, setMissing] = useState(false);
  const st = useApp.getState;

  const reload = () => api.sessionGet({ id }).then(setSummary).catch(() => setMissing(true));
  useEffect(() => {
    reload();
    st().openSessionDetail(id);
    const un = api.on("sessions:changed", () => reload());
    return () => {
      un();
      useApp.setState({ sessionDetail: null });
    };
  }, [id]);

  if (missing) return <Screen title="Session"><EmptyState icon="questionmark.folder" title="Session not found" /></Screen>;
  const s = summary?.session;
  const items = detail?.id === id ? detail.items : [];
  const ready = items.filter(isReady);

  const openLoupe = (captureId: string) => {
    useApp.setState((x) => ({ library: { ...x.library, loupeId: captureId } }));
    st().openModal({ kind: "loupe", origin: "session" });
  };

  return (
    <Screen
      title={s?.name ?? "Session"}
      trailing={
        s ? (
          <MenuButton label="More" title="More" align="right" minWidth={220} items={[
            { title: "Rename…", icon: "pencil", onSelect: () => st().openModal({ kind: "rename", title: "Rename session", value: s.name, onSave: (name) => api.sessionRename({ id, name }).then(reload).catch(st().fail) }) },
            { title: "Save as template…", icon: "doc.badge.plus", onSelect: () => api.templateFromSession({ sessionId: id }).then((t) => st().openModal({ kind: "templateEditor", template: t, isNew: true })) },
            { title: "Write manifest (JSON + CSV)", icon: "doc.text", onSelect: () => api.sessionManifest({ id }).then((r) => api.revealInFinder({ path: r.jsonPath })) },
            { title: "Import files into this session…", icon: "square.and.arrow.down", onSelect: () => importFiles(id) },
            { title: "Open in Library", icon: "photo.on.rectangle.angled", onSelect: () => st().selectSource({ kind: "session", id }) },
            { kind: "divider" },
            { title: "Delete session…", icon: "trash", destructive: true, onSelect: () => st().openModal({
              kind: "confirm", title: "Delete this session?", message: "Frames, ratings and exports in this session are removed from the Mac.", confirmTitle: "Delete", destructive: true, cancelTitle: "Keep",
              onConfirm: () => api.sessionDelete({ id }).then(pop).catch(st().fail),
            }) },
          ]}>
            <Icon name="ellipsis.circle" size={18} />
          </MenuButton>
        ) : null
      }
    >
      {s && summary ? (
        <div className="stack">
          <SectionCard>
            <span className="t-title">{s.name}</span>
            <span className="t-hud ink-1">
              {plural(items.length, "frame")} · {formatDateTime(s.createdAt)}{s.camera ? ` · ${cameraDisplayName(s.camera)}` : ""}
              {summary.counts.picks ? ` · ${summary.counts.picks} picks` : ""}
            </span>
            <div className="row wrap">
              {s.status !== "ended" ? (
                <button className="btn primary" onClick={() => api.sessionResume({ id }).then((state) => st().activate(state)).catch(st().fail)}>
                  <Icon name="play.fill" size={12} /> Resume
                </button>
              ) : null}
              <button className="btn secondary" disabled={!ready.length} onClick={() => openExport("session", [])}>
                <Icon name="square.and.arrow.up" size={14} /> Export
              </button>
              <button className="btn secondary" onClick={() => push({ kind: "exportProgress", sessionId: id })}>
                <Icon name="list.bullet" size={14} /> Exports
              </button>
            </div>
          </SectionCard>
          <div className="detail-grid">
            {items.map((item) => (
              <button
                key={item.id}
                className="detail-tile"
                style={{ opacity: item.flag === "reject" ? 0.4 : 1 }}
                onClick={() => isReady(item) && openLoupe(item.id)}
                onContextMenu={(e) => openContextMenu(e, [
                  { title: "Open in loupe", icon: "eye", onSelect: () => openLoupe(item.id) },
                  { kind: "divider" },
                  ...commandItems(commandsFor("session", [item.id]), (c) => runCommand(c, [item.id], "session"), ["select.", "camera.", "session.", "view.compare"]),
                ])}
                aria-label={`${item.filename}, ${item.rating} stars`}
              >
                <CaptureImage item={item} variant="thumb" />
                <span className="detail-badges">
                  {item.flag === "pick" ? <Icon name="flag.fill" size={10} className="c-ok" /> : null}
                  <RatingDots rating={item.rating} />
                  {item.kind === "raw" ? <span className="badge-mini">RAW</span> : null}
                </span>
              </button>
            ))}
          </div>
        </div>
      ) : null}
    </Screen>
  );
}
