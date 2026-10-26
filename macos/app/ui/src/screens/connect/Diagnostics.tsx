import { useEffect, useState } from "react";
import { api, type DiagnosticOutcome, type DiagnosticReport } from "../../api";
import { useApp } from "../../state/store";
import { Screen } from "../routes";
import { Labeled, TextField } from "../../components/controls";
import { SectionCard, Spinner } from "../../components/common";
import { Icon } from "../../components/Icon";

function OutcomeIcon({ o }: { o: DiagnosticOutcome }) {
  switch (o.kind) {
    case "pending": return <Icon name="circle" size={16} className="ink-2" />;
    case "running": return <Spinner small accent />;
    case "pass": return <Icon name="checkmark.circle.fill" size={16} className="c-ok" />;
    case "warn": return <Icon name="exclamationmark.triangle.fill" size={16} className="c-warn" />;
    case "fail": return <Icon name="xmark.circle.fill" size={16} className="c-danger" />;
    case "skipped": return <Icon name="minus.circle" size={16} className="ink-2" />;
  }
}

const outcomeColor = (o: DiagnosticOutcome) => (o.kind === "pass" ? "var(--ok)" : o.kind === "warn" ? "var(--warn)" : o.kind === "fail" ? "var(--danger)" : "var(--ink-1)");

/** Runs the wired or wireless checklist against the real transport (engine side). */
export function DiagnosticsBody({ wired }: { wired: boolean }) {
  const [report, setReport] = useState<DiagnosticReport | null>(null);
  const [running, setRunning] = useState(false);
  const [host, setHost] = useState("192.168.0.1");
  const [port, setPort] = useState("15740");

  useEffect(() => {
    if (!wired) api.discoveryStart().then((d) => { if (d.cameras[0]) { setHost(d.cameras[0].host); setPort(String(d.cameras[0].port)); } });
    const un = api.on("diagnostics:update", (r) => { if (r.wired === wired) setReport(r); });
    return () => {
      un();
      if (!wired) api.discoveryStop();
    };
  }, [wired]);

  const run = async () => {
    setRunning(true);
    try {
      setReport(await api.diagnosticsRun({ wired, host: wired ? null : host.trim(), port: wired ? null : Number(port) || 15740 }));
    } catch (e) {
      useApp.getState().fail(e);
    } finally {
      setRunning(false);
    }
  };

  return (
    <div className="stack">
      {!wired ? (
        <SectionCard title="Camera to probe" icon="network">
          <div className="row gap-m">
            <Labeled label="Host" style={{ flex: 1 }}><TextField mono value={host} onChange={setHost} label="Camera host" /></Labeled>
            <Labeled label="Port" style={{ width: 110 }}><TextField mono value={port} onChange={(v) => setPort(v.replace(/\D/g, ""))} label="Camera port" /></Labeled>
          </div>
        </SectionCard>
      ) : null}
      {report ? (
        <SectionCard title={report.verdict} icon="stethoscope">
          {report.checks.map((c) => (
            <div key={c.id} className="col" style={{ gap: 2, padding: "2px 0" }}>
              <div className="row"><OutcomeIcon o={c.outcome} /><span className="t-body" style={{ fontWeight: 500 }}>{c.title}</span></div>
              {"detail" in c.outcome ? <span className="t-callout" style={{ color: outcomeColor(c.outcome), paddingLeft: 24 }}>{c.outcome.detail}</span> : null}
              {c.outcome.kind === "fail" || c.outcome.kind === "warn" ? <span className="t-hud ink-2" style={{ paddingLeft: 24 }}>{c.tip}</span> : null}
            </div>
          ))}
        </SectionCard>
      ) : null}
      <button className="btn primary large block" disabled={running} onClick={run}>
        <Icon name="play.fill" size={12} /> {running ? "Checking…" : report ? "Run again" : "Run diagnostic"}
      </button>
      {report?.finishedAt ? (
        <button className="btn secondary block" onClick={() => navigator.clipboard?.writeText(report.shareText).then(() => useApp.getState().toast("Report copied", "doc.text"))}>
          <Icon name="doc.text" size={13} /> Copy report
        </button>
      ) : null}
    </div>
  );
}

export function Diagnostics({ wired }: { wired: boolean }) {
  return (
    <Screen title={wired ? "Cable diagnostic" : "Wireless diagnostic"} readable>
      <DiagnosticsBody wired={wired} />
    </Screen>
  );
}
