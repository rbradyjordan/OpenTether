import { createPortal } from "react-dom";
import { useApp } from "../state/store";
import type { Modal } from "../state/types";
import { CommandPalette } from "./commands/CommandPalette";
import { ConfirmSheet, RenameSheet } from "./commands/Dialogs";
import { StackView } from "./routes";
import { NewSessionSheet } from "./sessions/NewSessionSheet";
import { TemplateEditor } from "./sessions/TemplateEditor";
import { ExportSheet } from "./export/ExportSheet";
import { ExportProgressSheet } from "./export/ExportProgress";
import { FtpDestinationEditor } from "./export/FtpDestinations";
import { TagSheet } from "./library/TagEditor";
import { CollectionPicker } from "./library/CollectionPicker";
import { CollectionEditor } from "./library/CollectionEditor";
import { CatalogSync } from "./library/CatalogSync";
import { ManualIPSheet } from "./connect/ManualIPSheet";
import { LooksSheet } from "./looks/LooksSheet";
import { ColorMatch } from "./looks/ColorMatch";
import { PropertyPicker } from "./shoot/PropertyPicker";
import { ReconnectSheet } from "./shoot/ReconnectSheet";
import { DiagnosticsSheet } from "./shoot/DiagnosticsSheet";
import { Loupe } from "./review/Loupe";
import { Compare } from "./review/Compare";
import { ClientReview } from "./review/ClientReview";

const FULL_WINDOW = new Set(["loupe", "clientReview", "compare"]);
/** Sheets that should not close on a stray click outside. */
const STICKY = new Set(["confirm", "export", "newSession", "collectionEditor", "templateEditor", "ftpDestinationEditor", "catalogSync", "reconnect"]);

function ModalView({ m }: { m: Modal }) {
  const close = () => useApp.getState().closeModal(m.kind);
  switch (m.kind) {
    case "palette": return <CommandPalette onClose={close} />;
    case "settings":
      return (
        <div className="sheet settings-sheet" role="dialog" aria-label="Settings" onMouseDown={(e) => e.stopPropagation()}>
          <StackView stack="settings" inSheet />
        </div>
      );
    case "newSession": return <NewSessionSheet onClose={close} onCreated={m.onCreated} />;
    case "export": return <ExportSheet ctx={m.ctx} onClose={close} />;
    case "exportProgress": return <ExportProgressSheet sessionId={m.sessionId} onClose={close} />;
    case "tags": return <TagSheet ids={m.ids} onClose={close} />;
    case "collectionPicker": return <CollectionPicker ids={m.ids} onClose={close} />;
    case "collectionEditor": return <CollectionEditor draft={m.draft} pendingIds={m.pendingIds} onClose={close} />;
    case "catalogSync": return <CatalogSync path={m.path} onClose={close} />;
    case "templateEditor": return <TemplateEditor template={m.template} isNew={m.isNew} onClose={close} />;
    case "manualIP": return <ManualIPSheet onClose={close} />;
    case "ftpDestinationEditor": return <FtpDestinationEditor destination={m.destination} onClose={close} />;
    case "confirm": return <ConfirmSheet modal={m} onClose={close} />;
    case "rename": return <RenameSheet modal={m} onClose={close} />;
    case "looks": return <LooksSheet onClose={close} />;
    case "colorMatch": return <ColorMatch targetId={m.targetId ?? null} onClose={close} />;
    case "property": return <PropertyPicker property={m.property} onClose={close} />;
    case "reconnect": return <ReconnectSheet onClose={close} />;
    case "diagnosticsSheet": return <DiagnosticsSheet wired={m.wired} onClose={close} />;
    case "loupe": return <Loupe origin={m.origin} onClose={close} />;
    case "compare": return <Compare origin={m.origin} ids={m.ids} onClose={close} />;
    case "clientReview": return <ClientReview origin={m.origin} onClose={close} />;
  }
}

export function ModalHost() {
  const modals = useApp((s) => s.modals);
  if (!modals.length) return null;
  return createPortal(
    <>
      {modals.map((m, i) =>
        FULL_WINDOW.has(m.kind) ? (
          <div key={`${m.kind}-${i}`} className="overlay-layer" style={{ zIndex: 400 + i * 2 }}>
            <ModalView m={m} />
          </div>
        ) : (
          <div
            key={`${m.kind}-${i}`}
            className={`modal-layer${m.kind === "palette" ? " palette-layer" : ""}`}
            style={{ zIndex: 400 + i * 2 + 1 }}
            onMouseDown={() => {
              if (!STICKY.has(m.kind)) useApp.getState().closeModal(m.kind);
            }}
          >
            <ModalView m={m} />
          </div>
        ),
      )}
    </>,
    document.body,
  );
}
