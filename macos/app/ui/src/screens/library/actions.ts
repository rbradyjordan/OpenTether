import { api } from "../../api";
import { useApp } from "../../state/store";

/** Native file picker → import into a session (or a new "Import" session). */
export async function importFiles(sessionId: string | null) {
  const s = useApp.getState();
  try {
    const paths = await api.dialogPick({ kind: "files", multiple: true });
    if (!paths.length) return;
    if (sessionId && s.shoot?.session.id === sessionId) await api.shootImportFiles({ paths });
    else await api.libraryImport({ paths, sessionId });
  } catch (e) {
    s.fail(e);
  }
}

/** Lightroom Classic / Capture One catalog → the sync sheet. */
export async function pickCatalog() {
  const s = useApp.getState();
  try {
    const [path] = await api.dialogPick({ kind: "catalog", multiple: false });
    if (path) s.openModal({ kind: "catalogSync", path });
  } catch (e) {
    s.fail(e);
  }
}
