import { useState } from "react";
import { useApp } from "../../state/store";
import { Screen, useStack } from "../routes";
import { FormRow, FormSection, TextField } from "../../components/controls";
import { IconTile } from "../../components/common";
import { Icon } from "../../components/Icon";
import type { Route } from "../../state/types";

function LinkRow({ title, icon, route, onClick }: { title: string; icon: string; route?: Route; onClick?: () => void }) {
  const { push } = useStack();
  return (
    <button className="list-row interactive" style={{ padding: "6px 4px" }} onClick={() => (route ? push(route) : onClick?.())}>
      <IconTile name={icon} size={28} />
      <span className="fill">{title}</span>
      <Icon name="chevron.right" size={13} className="ink-2" />
    </button>
  );
}

/** Grouped settings. Everything here is on the Mac; there is no account. */
export function Settings() {
  const settings = useApp((s) => s.settings);
  const info = useApp((s) => s.info);
  const [user, setUser] = useState(settings?.ftpUsername ?? "");
  const [pass, setPass] = useState(settings?.ftpPassword ?? "");
  const [port, setPort] = useState(String(settings?.ftpPort ?? 2121));
  const dirty = settings && (user !== settings.ftpUsername || pass !== settings.ftpPassword || port !== String(settings.ftpPort));
  return (
    <Screen title="Settings" readable>
      <div className="stack" style={{ gap: 20 }}>
        <FormSection title="FTP receiver" footer="Enter the same username, password and port in your camera's FTP settings.">
          <FormRow label="Username"><div className="form-control"><TextField value={user} onChange={setUser} label="FTP username" /></div></FormRow>
          <FormRow label="Password"><div className="form-control"><TextField mono value={pass} onChange={setPass} label="FTP password" /></div></FormRow>
          <FormRow label="Port"><div className="form-control"><TextField mono value={port} onChange={(v) => setPort(v.replace(/\D/g, ""))} label="FTP port" /></div></FormRow>
          <FormRow label="">
            <button className="btn secondary small" disabled={!dirty || !user || !pass}
              onClick={() => useApp.getState().updateSettings({ ftpUsername: user, ftpPassword: pass, ftpPort: Number(port) || 2121 })}>
              Save FTP login
            </button>
          </FormRow>
        </FormSection>
        <FormSection title="Exports">
          <LinkRow title="Saved folders" icon="folder" route={{ kind: "folderDestinations" }} />
          <LinkRow title="FTP destinations" icon="server.rack" route={{ kind: "ftpDestinations" }} />
          <LinkRow title="Creator & copyright" icon="person.text.rectangle" route={{ kind: "metadata" }} />
        </FormSection>
        <FormSection title="Help">
          <LinkRow title="Camera setup guides" icon="book.pages" route={{ kind: "brandGuides" }} />
          <LinkRow title="Tested cameras" icon="camera" route={{ kind: "testedCameras" }} />
          <LinkRow title="Check a USB cable" icon="cable.connector" route={{ kind: "diagnostics", wired: true }} />
          <LinkRow title="Check a Wi-Fi link" icon="wifi" route={{ kind: "diagnostics", wired: false }} />
          <LinkRow title="Camera conversation log" icon="list.bullet.rectangle" route={{ kind: "ptpLog" }} />
          <LinkRow title="Replay the intro" icon="sparkles" onClick={() => {
            useApp.getState().closeModal("settings");
            useApp.getState().updateSettings({ hasOnboarded: false });
          }} />
        </FormSection>
        <FormSection title="About">
          <LinkRow title="Privacy & legal" icon="hand.raised" route={{ kind: "privacy" }} />
          <LinkRow title="About Open Tether" icon="info.circle" route={{ kind: "about" }} />
        </FormSection>
        <div className="t-hud ink-2" style={{ textAlign: "center" }}>
          Open Tether {info?.version} · {info?.backend === "mock" ? "browser preview with demo data" : info?.platform}
        </div>
      </div>
    </Screen>
  );
}
