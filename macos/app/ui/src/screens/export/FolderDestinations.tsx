import { useEffect, useState } from "react";
import { api, type FolderDestination, type FolderKind } from "../../api";
import { useApp } from "../../state/store";
import { Screen } from "../routes";
import { IconTile } from "../../components/common";
import { Select } from "../../components/controls";
import { Icon } from "../../components/Icon";

export const FOLDER_KIND_TITLES: Record<FolderKind, string> = {
  plain: "Folder", captureOneSession: "Capture One session", lightroomAutoImport: "Lightroom Auto Import",
};
export const folderSymbol = (k: FolderKind) => (k === "captureOneSession" ? "camera.aperture" : k === "lightroomAutoImport" ? "square.and.arrow.down.on.square" : "folder");

/** Folders exports (and the hot folder) can use; each remembers which tool it belongs to. */
export function FolderDestinations() {
  const [folders, setFolders] = useState<FolderDestination[]>([]);
  const reload = () => api.folderDestinationsList().then(setFolders).catch(useApp.getState().fail);
  useEffect(() => {
    reload();
  }, []);
  const add = async () => {
    const [path] = await api.dialogPick({ kind: "folder", multiple: false });
    if (!path) return;
    await api.folderDestinationAdd({ path }).catch(useApp.getState().fail);
    reload();
  };
  return (
    <Screen title="Saved folders" readable trailing={<button className="btn secondary small" onClick={add}><Icon name="folder.badge.plus" size={13} /> Add a folder…</button>}>
      <div className="stack">
        {!folders.length ? <div className="t-callout">No folders yet. Add one from iCloud Drive, a server, an external drive or any Finder location.</div> : null}
        {folders.map((f) => (
          <div key={f.id} className="card row gap-m">
            <IconTile name={folderSymbol(f.kind)} size={34} />
            <div className="col fill" style={{ gap: 0 }}>
              <span className="t-headline">{f.name}</span>
              <span className="t-hud ink-2 truncate">{f.path}</span>
            </div>
            <Select<FolderKind> label="Kind" value={f.kind} style={{ width: 210 }}
              options={(Object.keys(FOLDER_KIND_TITLES) as FolderKind[]).map((k) => ({ value: k, label: FOLDER_KIND_TITLES[k] }))}
              onChange={(kind) => api.folderDestinationSetKind({ id: f.id, kind }).then(reload)} />
            <button className="icon-btn" aria-label={`Remove ${f.name}`} title="Remove" onClick={() => api.folderDestinationDelete({ id: f.id }).then(reload)}>
              <Icon name="trash" size={14} />
            </button>
          </div>
        ))}
        <div className="t-hud ink-2">
          Pick the root of a Capture One session and Open Tether writes straight into its Capture, Selects and Trash folders. Mark a folder as Lightroom Auto Import to keep it flat with sidecars written first.
        </div>
      </div>
    </Screen>
  );
}
