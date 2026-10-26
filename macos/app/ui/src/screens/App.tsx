import { useEffect } from "react";
import { useApp } from "../state/store";
import { Sidebar } from "./Sidebar";
import { StackView } from "./routes";
import { LibraryContent } from "./library/LibraryContent";
import { Inspector } from "./library/Inspector";
import { ShootScreen } from "./shoot/ShootScreen";
import { ModalHost } from "./ModalHost";
import { Onboarding } from "./onboarding/Onboarding";
import { ToastHost } from "../components/Toasts";
import { MenuHost } from "../components/Menu";
import { useKeyRouter } from "./keyboard";
import { Icon } from "../components/Icon";
import { Spinner } from "../components/common";
import { isLiveStatus, cameraDisplayName } from "../api";

export function App() {
  const ready = useApp((s) => s.ready);
  const bootError = useApp((s) => s.bootError);
  const onboarded = useApp((s) => s.settings?.hasOnboarded ?? false);
  useEffect(() => {
    useApp.getState().boot();
  }, []);
  useKeyRouter();

  if (!ready) {
    return (
      <div className="boot">
        <Spinner />
      </div>
    );
  }
  if (bootError) {
    return (
      <div className="boot col" style={{ gap: 12 }}>
        <Icon name="exclamationmark.triangle" size={32} className="c-warn" />
        <div className="t-title">Open Tether couldn't start</div>
        <div className="t-callout selectable">{bootError}</div>
      </div>
    );
  }
  return (
    <>
      {onboarded ? <MainWindow /> : <Onboarding />}
      <ModalHost />
      <MenuHost />
      <ToastHost />
    </>
  );
}

/** Sidebar (sources) · content (library, Connect or Sessions) · inspector. The shoot covers the window. */
function MainWindow() {
  const pane = useApp((s) => s.pane);
  const inspectorOpen = useApp((s) => s.library.inspectorOpen);
  const showShoot = useApp((s) => s.showShoot);
  return (
    <div className="main-window">
      <Sidebar />
      <main className="content-column">
        {pane === "library" ? <LibraryContent /> : <StackView stack={pane === "connect" ? "connect" : "sessions"} />}
      </main>
      {pane === "library" && inspectorOpen ? <Inspector /> : null}
      {!showShoot ? <LivePill /> : null}
      {showShoot ? <ShootScreen /> : null}
    </div>
  );
}

/** Brings the shoot back from anywhere in the library. */
function LivePill() {
  const shoot = useApp((s) => s.shoot);
  if (!shoot) return null;
  const live = isLiveStatus(shoot.status);
  const name = shoot.identity ? cameraDisplayName(shoot.identity) : shoot.isDemo ? "Demo camera" : "FTP receiver";
  return (
    <button className="live-pill" onClick={() => useApp.getState().setShowShoot(true)} aria-label={`Return to the live shoot with ${name}`}>
      <span className={`live-dot${live ? " on" : ""}`} />
      <span className="t-hud">{live ? `Live · ${name}` : `Session · ${name}`}</span>
      <Icon name="chevron.up" size={12} strokeWidth={2.4} />
    </button>
  );
}
