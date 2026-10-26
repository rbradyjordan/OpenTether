import { createContext, useContext, type ReactNode } from "react";
import { useApp } from "../state/store";
import type { Route, StackName } from "../state/types";
import { ScreenHeader } from "../components/common";
import { Icon } from "../components/Icon";
import { VENDOR_NAMES } from "../api";
import { ConnectHub } from "./connect/ConnectHub";
import { UsbConnect } from "./connect/UsbConnect";
import { WifiConnect } from "./connect/WifiConnect";
import { FtpReceiver } from "./connect/FtpReceiver";
import { BrandGuides, BrandGuideDetail } from "./connect/BrandGuides";
import { Diagnostics } from "./connect/Diagnostics";
import { SessionsHome } from "./sessions/SessionsHome";
import { SessionDetail } from "./sessions/SessionDetail";
import { ExportProgress } from "./export/ExportProgress";
import { FtpDestinations } from "./export/FtpDestinations";
import { FolderDestinations } from "./export/FolderDestinations";
import { Settings } from "./settings/Settings";
import { MetadataSettings } from "./settings/MetadataSettings";
import { TestedCameras } from "./settings/TestedCameras";
import { PtpLog } from "./settings/PtpLog";
import { Privacy, About } from "./settings/About";

export function routeTitle(r: Route): string {
  switch (r.kind) {
    case "connectHub": return "Connect";
    case "usb": return "USB-C";
    case "wifi": return "Wi-Fi";
    case "ftpReceiver": return "FTP push";
    case "brandGuides": return "Setup guides";
    case "brandGuide": return VENDOR_NAMES[r.vendor];
    case "diagnostics": return r.wired ? "Cable diagnostic" : "Wireless diagnostic";
    case "sessionsHome": return "Sessions";
    case "sessionDetail": return "Session";
    case "exportProgress": return "Exports";
    case "ftpDestinations": return "FTP destinations";
    case "folderDestinations": return "Saved folders";
    case "settings": return "Settings";
    case "metadata": return "Metadata";
    case "testedCameras": return "Tested cameras";
    case "ptpLog": return "Camera conversation log";
    case "privacy": return "Privacy & legal";
    case "about": return "About";
  }
}

interface StackCtx {
  stack: StackName;
  depth: number;
  backTitle: string | null;
  /** Shown inside a sheet (Settings): the sheet supplies the close button. */
  inSheet: boolean;
}

const Ctx = createContext<StackCtx>({ stack: "connect", depth: 0, backTitle: null, inSheet: false });

export function useStack() {
  const ctx = useContext(Ctx);
  return {
    ...ctx,
    push: (r: Route) => useApp.getState().push(ctx.stack, r),
    pop: () => useApp.getState().pop(ctx.stack),
  };
}

/** A pushed screen: header with back button, then scrolling content. */
export function Screen({
  title, trailing, children, padded = true, scroll = true, readable = false,
}: { title: string; trailing?: ReactNode; children: ReactNode; padded?: boolean; scroll?: boolean; readable?: boolean }) {
  const { depth, backTitle, pop, inSheet } = useStack();
  const close = inSheet ? (
    <button className="icon-btn round" aria-label="Close" title="Close (Esc)" onClick={() => useApp.getState().closeModal("settings")}>
      <Icon name="xmark" size={14} strokeWidth={2.2} />
    </button>
  ) : null;
  return (
    <div className="screen">
      <ScreenHeader title={title} onBack={depth > 0 ? pop : undefined} backTitle={backTitle ?? undefined} trailing={<>{trailing}{close}</>} />
      <div className={`screen-body${scroll ? " scroll" : ""}`}>
        <div className={`${padded ? "screen-pad" : ""}${readable ? " readable" : ""}`} style={readable ? undefined : { height: scroll ? undefined : "100%" }}>
          {children}
        </div>
      </div>
    </div>
  );
}

function RouteView({ route }: { route: Route }) {
  switch (route.kind) {
    case "connectHub": return <ConnectHub />;
    case "usb": return <UsbConnect />;
    case "wifi": return <WifiConnect />;
    case "ftpReceiver": return <FtpReceiver />;
    case "brandGuides": return <BrandGuides />;
    case "brandGuide": return <BrandGuideDetail vendor={route.vendor} />;
    case "diagnostics": return <Diagnostics wired={route.wired} />;
    case "sessionsHome": return <SessionsHome />;
    case "sessionDetail": return <SessionDetail id={route.id} />;
    case "exportProgress": return <ExportProgress sessionId={route.sessionId} />;
    case "ftpDestinations": return <FtpDestinations />;
    case "folderDestinations": return <FolderDestinations />;
    case "settings": return <Settings />;
    case "metadata": return <MetadataSettings />;
    case "testedCameras": return <TestedCameras />;
    case "ptpLog": return <PtpLog />;
    case "privacy": return <Privacy />;
    case "about": return <About />;
  }
}

export function StackView({ stack, inSheet = false }: { stack: StackName; inSheet?: boolean }) {
  const routes = useApp((s) => s.stacks[stack]);
  const depth = routes.length - 1;
  const top = routes[depth];
  const back = depth > 0 ? routeTitle(routes[depth - 1]) : null;
  return (
    <Ctx.Provider value={{ stack, depth, backTitle: back, inSheet }}>
      <div className="stack-view" key={`${stack}-${depth}-${top.kind}`}>
        <RouteView route={top} />
      </div>
    </Ctx.Provider>
  );
}
