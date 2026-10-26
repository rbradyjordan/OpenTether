import { useEffect } from "react";
import type { ReconnectStrategy } from "../../api";
import { useApp } from "../../state/store";
import { Icon } from "../../components/Icon";
import { Spinner, TonePill } from "../../components/common";
import { firstSentence } from "../../lib/format";

export function strategyTitle(s: ReconnectStrategy): string {
  switch (s.kind) {
    case "waitForUsbDevice": return "Waiting for the cable";
    case "retryHost": return `Reconnecting to ${s.host}`;
    case "retryRicoh": return `Reconnecting to the Ricoh at ${s.host}`;
    case "retryHttp": return `Reconnecting to the ${s.vendor === "gopro" ? "GoPro" : "camera"}`;
    case "nothingToDo": return "FTP receiver is still listening";
    case "startFresh": return "Connect again";
  }
}

export function strategyDetail(s: ReconnectStrategy): string {
  switch (s.kind) {
    case "waitForUsbDevice": return "Plug the camera back in. Open Tether reconnects as soon as it reappears and keeps every frame from this session.";
    case "retryHost": return "Make sure the Mac is still on the camera's Wi-Fi and the camera is in its PC / remote connection mode.";
    case "retryRicoh": return "Stay on the camera's Wi-Fi network. The GR sleeps quickly; half-press the shutter to wake it.";
    case "retryHttp": return s.vendor === "gopro" ? "Keep the Mac on the GoPro's Wi-Fi and the camera awake (press Mode to wake it)." : "Keep the Mac on the camera's Wi-Fi network and the camera switched on.";
    case "nothingToDo": return "Cameras push files whenever they want; the session keeps collecting them.";
    case "startFresh": return "Open Tether does not know how this session was connected. Pick a connection method to continue it.";
  }
}

/** Disconnect is a dim and a sheet, never an alert: the strategy in one sentence, one button, and a way out. */
export function ReconnectSheet({ onClose }: { onClose: () => void }) {
  const shoot = useApp((s) => s.shoot);
  const reconnecting = useApp((s) => s.reconnecting);
  const error = useApp((s) => s.reconnectError);
  const strategy = shoot?.reconnect ?? { kind: "startFresh" as const };

  // USB: start waiting for the device the moment the sheet appears.
  useEffect(() => {
    if (strategy.kind === "waitForUsbDevice" && shoot?.status.kind === "disconnected") useApp.getState().reconnect();
  }, []);

  const st = useApp.getState;
  const primary = () => {
    if (strategy.kind === "nothingToDo") return onClose();
    if (strategy.kind === "startFresh") {
      onClose();
      st().endShoot().then(() => {
        st().setPane("connect");
        st().popTo("connect", 0);
      });
      return;
    }
    st().reconnect();
  };

  return (
    <div className="sheet reconnect-sheet" role="dialog" aria-label="Connection lost" onMouseDown={(e) => e.stopPropagation()}>
      <div className="row">
        <TonePill text="Connection lost" tone="danger" icon="bolt.slash" />
        <span className="spacer" />
        {reconnecting ? <Spinner small /> : null}
        <button className="icon-btn round" onClick={onClose} aria-label="Close" title="Not now (Esc)"><Icon name="xmark" size={14} strokeWidth={2.2} /></button>
      </div>
      <div className="t-title">{strategyTitle(strategy)}</div>
      <div className="t-callout">{firstSentence(strategyDetail(strategy))}</div>
      {error ? <div className="t-hud c-danger">{error}</div> : null}
      <button className="btn primary large block" disabled={reconnecting} onClick={primary}>
        {strategy.kind === "nothingToDo" ? "Continue" : strategy.kind === "startFresh" ? "Go to Connect" : reconnecting ? "Reconnecting…" : "Reconnect now"}
      </button>
      <div className="row">
        <button className="btn plain quiet" onClick={() => { if (reconnecting) st().cancelReconnect(); onClose(); }}>Not now</button>
        <span className="spacer" />
        <button className="btn plain danger" onClick={() => { onClose(); st().endShoot(); }}>End session</button>
      </div>
    </div>
  );
}
