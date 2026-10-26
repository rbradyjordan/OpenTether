import { useApp } from "../../state/store";
import { Screen } from "../routes";
import { SectionCard } from "../../components/common";
import { Icon } from "../../components/Icon";

export function About() {
  const info = useApp((s) => s.info);
  return (
    <Screen title="About" readable>
      <div className="col" style={{ alignItems: "center", gap: 14, textAlign: "center", paddingTop: 24 }}>
        <span className="about-mark"><Icon name="camera.aperture" size={64} strokeWidth={1.3} /></span>
        <span className="t-display">Open Tether</span>
        <span className="t-callout">Version {info?.version} ({info?.build})</span>
        <span className="t-body" style={{ maxWidth: 440 }}>
          Camera tethering for the Mac: USB-C, Wi-Fi and FTP push, with looks, client review and resumable exports.
        </span>
        <span className="t-hud ink-2">Made by Brady Jordan.</span>
      </div>
    </Screen>
  );
}

export function Privacy() {
  return (
    <Screen title="Privacy & legal" readable>
      <div className="stack">
        <SectionCard title="What stays on the Mac" icon="desktopcomputer">
          <span className="t-callout ink-0">
            Every capture, rating, look and session lives in the app's own storage. Open Tether has no account, no servers and no in-app purchases; it is free.
            Files only leave the Mac when you export them to a destination you chose.
          </span>
        </SectionCard>
        <SectionCard title="What Open Tether never does" icon="hand.raised">
          <span className="t-callout ink-0">
            • Join a Wi-Fi network for you. You pick the camera's network in the Wi-Fi menu.<br />
            • Upload photos in the background.<br />
            • Browse your photo library. Exports are only added to it.
          </span>
        </SectionCard>
        <SectionCard title="Generic PTP import vs vendor control" icon="camera.badge.ellipsis">
          <span className="t-callout ink-0">
            Any PTP camera can be imported from over USB using the standard Picture Transfer Protocol. Remote capture, live view and exposure control use each
            maker's documented or community-documented extensions; brand names are used only to describe compatibility.
          </span>
        </SectionCard>
      </div>
    </Screen>
  );
}
