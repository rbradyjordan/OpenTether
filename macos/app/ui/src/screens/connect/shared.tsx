import { useEffect, useState } from "react";
import { api, type ConnectProgress, type ShootSession, type StepState } from "../../api";
import { useApp } from "../../state/store";
import { Icon } from "../../components/Icon";
import { MenuButton, type MenuItem } from "../../components/Menu";
import { Spinner } from "../../components/common";
import { firstSentence } from "../../lib/format";

/** "Which session does this connection feed?" Shared by the three connect screens. */
export function SessionPicker({ value, onChange }: { value: string | null; onChange: (id: string | null) => void }) {
  const sessions = useApp((s) => s.sessions);
  const open = sessions.filter((s) => s.session.status !== "ended");
  useEffect(() => {
    if (value == null && open[0]) onChange(open[0].session.id);
  }, []);
  const current = sessions.find((s) => s.session.id === value)?.session;
  const items: MenuItem[] = [
    { title: "New session…", icon: "plus", onSelect: () => useApp.getState().openModal({ kind: "newSession", onCreated: (s: ShootSession) => onChange(s.id) }) },
    { title: "A new session named after today", icon: "calendar", checked: value == null, onSelect: () => onChange(null) },
    ...(open.length ? [{ kind: "divider" } as MenuItem] : []),
    ...open.slice(0, 8).map((s): MenuItem => ({ title: s.session.name, checked: s.session.id === value, onSelect: () => onChange(s.session.id) })),
  ];
  return (
    <div className="card row" style={{ padding: "10px 14px" }}>
      <Icon name="rectangle.stack" size={16} className="ink-1" />
      <div className="col fill" style={{ gap: 0 }}>
        <span className="t-caption">Session</span>
        <span className="t-body truncate" style={{ fontWeight: 500 }}>{current?.name ?? "New session (named after today)"}</span>
      </div>
      <MenuButton className="btn secondary small" items={items} align="right" minWidth={260} label="Choose session">
        Choose <Icon name="chevron.up.chevron.down" size={11} />
      </MenuButton>
    </div>
  );
}

function StepIcon({ state }: { state: StepState }) {
  if (state === "running") return <Spinner small accent />;
  if (state === "done") return <Icon name="checkmark.circle.fill" size={18} className="c-ok" />;
  if (state === "failed") return <Icon name="xmark.circle.fill" size={18} className="c-danger" />;
  return <span style={{ width: 16, height: 16, borderRadius: 8, border: "1.5px solid var(--hairline)", display: "inline-block" }} />;
}

/** Step list for a connect attempt; a failure is one sentence and one button. */
export function ConnectingProgress({ progress, onDismiss }: { progress: ConnectProgress; onDismiss: () => void }) {
  const failed = progress.failure != null;
  return (
    <div className="card col arrive" style={{ gap: 10 }}>
      <div className="row">
        <span className="t-headline">{failed ? "Could not connect" : "Connecting"}</span>
        <span className="spacer" />
        {!failed ? <Spinner small /> : null}
      </div>
      <div className="col" style={{ gap: 6 }}>
        {progress.steps.map((s) => (
          <div key={s.step} className="row" style={{ minHeight: 24 }}>
            <span style={{ width: 20, display: "inline-flex", justifyContent: "center" }}><StepIcon state={s.state} /></span>
            <span className="t-callout" style={{ color: s.state === "pending" ? "var(--ink-2)" : "var(--ink-0)" }}>{s.title}</span>
            <span className="spacer" />
            <span className="t-caption">{s.state === "pending" ? "waiting" : s.state === "running" ? "now" : s.state}</span>
          </div>
        ))}
      </div>
      {failed ? <div className="t-callout c-danger">{firstSentence(progress.failure ?? "")}</div> : null}
      <button className={`btn ${failed ? "secondary" : "secondary quiet"}`} onClick={() => {
        if (!failed) api.connectCancel();
        onDismiss();
      }}>
        {failed ? "Try again" : "Cancel"}
      </button>
    </div>
  );
}

/** Tracks the store's connect progress for one screen. */
export function useConnectProgress() {
  const progress = useApp((s) => s.connect);
  const [visible, setVisible] = useState(false);
  return {
    progress: visible ? progress : null,
    begin: () => {
      useApp.setState({ connect: null });
      setVisible(true);
    },
    dismiss: () => {
      setVisible(false);
      useApp.setState({ connect: null });
    },
  };
}
