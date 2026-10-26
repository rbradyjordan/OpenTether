import { useEffect, useState } from "react";
import { api, errorMessage, type FtpDestination, type FtpSecurity } from "../../api";
import { useApp } from "../../state/store";
import { Screen } from "../routes";
import { Sheet, SheetActions } from "../../components/Sheet";
import { EmptyState, Spinner } from "../../components/common";
import { FormRow, FormSection, Select, TextField, Toggle } from "../../components/controls";
import { Icon } from "../../components/Icon";
import { openContextMenu } from "../../components/Menu";

function useFtpList() {
  const [list, setList] = useState<FtpDestination[]>([]);
  const modals = useApp((s) => s.modals.length);
  useEffect(() => {
    api.ftpDestinationsList().then(setList).catch(useApp.getState().fail);
  }, [modals]);
  return [list, setList] as const;
}

export function FtpDestinations() {
  const [list, setList] = useFtpList();
  const st = useApp.getState;
  const remove = (d: FtpDestination) => st().openModal({
    kind: "confirm", title: `Delete ${d.name}?`, message: "Exports already sent stay on the server. The saved password is removed from the Keychain.",
    confirmTitle: "Delete", destructive: true,
    onConfirm: () => api.ftpDestinationDelete({ id: d.id }).then(() => api.ftpDestinationsList().then(setList)),
  });
  return (
    <Screen title="FTP destinations" readable trailing={
      <button className="btn secondary small" onClick={() => st().openModal({ kind: "ftpDestinationEditor", destination: null })}><Icon name="plus" size={13} /> Add</button>
    }>
      {!list.length ? (
        <EmptyState icon="server.rack" title="No FTP destinations" message="Add a studio or client server to push exports straight to it." action="Add destination"
          onAction={() => st().openModal({ kind: "ftpDestinationEditor", destination: null })} />
      ) : (
        <div className="form-group" style={{ background: "var(--surface-2)", borderRadius: 12, padding: 4 }}>
          {list.map((d) => (
            <div key={d.id} role="button" tabIndex={0} className="list-row interactive" onClick={() => st().openModal({ kind: "ftpDestinationEditor", destination: d })}
              onContextMenu={(e) => openContextMenu(e, [
                { title: "Edit…", icon: "pencil", onSelect: () => st().openModal({ kind: "ftpDestinationEditor", destination: d }) },
                { title: "Delete", icon: "trash", destructive: true, onSelect: () => remove(d) },
              ])}>
              <Icon name="server.rack" size={18} className="ink-1" />
              <span className="col fill" style={{ gap: 0 }}>
                <span className="t-headline">{d.name}</span>
                <span className="t-hud ink-2 truncate">{d.username}@{d.host}:{d.port} · {d.security} · {d.remoteDirectory}</span>
              </span>
              <button className="icon-btn" aria-label={`Delete ${d.name}`} title="Delete" onClick={(e) => { e.stopPropagation(); remove(d); }}><Icon name="trash" size={14} /></button>
            </div>
          ))}
        </div>
      )}
    </Screen>
  );
}

export function FtpDestinationEditor({ destination, onClose }: { destination: FtpDestination | null; onClose: () => void }) {
  const [d, setD] = useState<FtpDestination>(destination ?? { id: "", name: "", host: "", port: 21, username: "", security: "explicitTLS", passive: true, remoteDirectory: "/" });
  const [password, setPassword] = useState("");
  const [testing, setTesting] = useState(false);
  const [result, setResult] = useState<{ ok: boolean; text: string } | null>(null);
  useEffect(() => {
    if (destination) api.ftpDestinationPassword({ id: destination.id }).then((p) => setPassword(p ?? ""));
  }, [destination]);
  const set = (patch: Partial<FtpDestination>) => setD((x) => ({ ...x, ...patch }));

  const save = async () => {
    try {
      await api.ftpDestinationSave({ destination: d, password });
      onClose();
    } catch (e) {
      setResult({ ok: false, text: errorMessage(e) });
    }
  };
  const test = async () => {
    setTesting(true);
    setResult(null);
    try {
      setResult({ ok: true, text: await api.ftpDestinationTest({ destination: d, password }) });
    } catch (e) {
      setResult({ ok: false, text: errorMessage(e) });
    } finally {
      setTesting(false);
    }
  };

  return (
    <Sheet title={destination ? "Edit destination" : "New destination"} onClose={onClose} width={520}
      footer={<SheetActions onCancel={onClose} primaryTitle="Save" onPrimary={save} primaryDisabled={!d.name || !d.host || !d.username}
        leading={<button className="btn secondary small" disabled={testing || !d.host} onClick={test}>{testing ? <Spinner small /> : null}{testing ? "Testing…" : "Test connection"}</button>} />}>
      <FormSection title="Server">
        <FormRow label="Name"><div className="form-control"><TextField value={d.name} onChange={(name) => set({ name })} placeholder="Studio NAS" autoFocus /></div></FormRow>
        <FormRow label="Host"><div className="form-control"><TextField value={d.host} onChange={(host) => set({ host })} placeholder="nas.local" /></div></FormRow>
        <FormRow label="Port"><div className="form-control"><TextField value={String(d.port)} onChange={(v) => set({ port: Number(v.replace(/\D/g, "")) || 0 })} /></div></FormRow>
        <FormRow label="Security">
          <div className="form-control">
            <Select<FtpSecurity> label="Security" value={d.security} onChange={(security) => {
              set({ security, port: security === "implicitTLS" && d.port === 21 ? 990 : security !== "implicitTLS" && d.port === 990 ? 21 : d.port });
            }} options={[{ value: "plain", label: "Plain FTP" }, { value: "explicitTLS", label: "Explicit TLS (FTPES)" }, { value: "implicitTLS", label: "Implicit TLS (990)" }]} />
          </div>
        </FormRow>
        <FormRow label="Passive mode"><Toggle on={d.passive} onChange={(passive) => set({ passive })} label="Passive mode" /></FormRow>
      </FormSection>
      <FormSection title="Login" footer="The password is kept in the macOS Keychain.">
        <FormRow label="Username"><div className="form-control"><TextField value={d.username} onChange={(username) => set({ username })} /></div></FormRow>
        <FormRow label="Password"><div className="form-control"><TextField type="password" value={password} onChange={setPassword} label="Password" /></div></FormRow>
        <FormRow label="Remote directory"><div className="form-control"><TextField mono value={d.remoteDirectory} onChange={(remoteDirectory) => set({ remoteDirectory })} /></div></FormRow>
      </FormSection>
      {result ? <div className={`t-callout ${result.ok ? "c-ok" : "c-danger"}`}>{result.text}</div> : null}
    </Sheet>
  );
}
