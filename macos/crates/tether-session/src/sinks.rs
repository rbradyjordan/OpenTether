//! Where exports land (`Tether/Adapters/FilesExportSink.swift`,
//! `FolderAccess.swift`, `PhotosExportSink.swift`, the FTP uploader in
//! `AppServices.swift`). The export queue knows one sink; this one routes
//! by destination.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use tether_library::delivery::{
    ExportDestination, ExportItem, ExportSink, Uploader, UploaderFactory,
};
use tether_library::store::StoredFtpDestination;
use tether_library::SessionStore;
use tether_net::{FtpClient, FtpDestination, FtpSecurity};

use crate::platform::{PhotoLibrary, SecretStore};

fn delivery(e: impl std::fmt::Display) -> tether_library::Error {
    tether_library::Error::Delivery(e.to_string())
}

/// The settings key holding a saved folder's resolved path. The shell
/// resolves security-scoped bookmarks and hands us the path; the bookmark
/// itself is kept on the [`tether_library::store::StoredFolderDestination`].
pub fn folder_path_key(id: &str) -> String {
    format!("folder.path.{id}")
}

pub fn folder_path(store: &SessionStore, id: &str) -> Option<PathBuf> {
    store.setting(&folder_path_key(id)).map(PathBuf::from)
}

fn session_folder_name(store: &SessionStore, item: &ExportItem) -> String {
    let session = store
        .capture(&item.id)
        .ok()
        .flatten()
        .and_then(|c| store.session(&c.session_id).ok().flatten());
    let Some(session) = session else {
        return "Open Tether".into();
    };
    let cleaned: String = session
        .name
        .chars()
        .map(|c| if "/\\:\0".contains(c) { '-' } else { c })
        .collect();
    if cleaned.trim().is_empty() {
        session.directory_name()
    } else {
        cleaned
    }
}

fn unique_path(dir: &Path, preferred: &str) -> PathBuf {
    let mut p = dir.join(preferred);
    let (base, ext) = match preferred.rfind('.') {
        Some(i) if i > 0 => (&preferred[..i], &preferred[i + 1..]),
        _ => (preferred, ""),
    };
    let mut n = 1;
    while p.exists() {
        p = dir.join(if ext.is_empty() {
            format!("{base}-{n}")
        } else {
            format!("{base}-{n}.{ext}")
        });
        n += 1;
    }
    p
}

/// Copy `source` to `relative` under `root`, replacing what is there
/// (re-exports update files instead of piling up "-1" copies). The copy
/// lands under a hidden temporary name first, so watched folders never see
/// a half-written photo.
pub fn place(source: &Path, relative: &str, root: &Path) -> std::io::Result<PathBuf> {
    let target = root.join(relative);
    let dir = target.parent().unwrap_or(root).to_path_buf();
    std::fs::create_dir_all(&dir)?;
    let temp = dir.join(format!(
        ".{}.opentether-part",
        target.file_name().unwrap_or_default().to_string_lossy()
    ));
    let _ = std::fs::remove_file(&temp);
    std::fs::copy(source, &temp)?;
    std::fs::rename(&temp, &target)?;
    Ok(target)
}

/// Routes deliveries: Photos, the app's exports folder (Files / Share), or
/// a folder the user picked. FTP never reaches a sink (the queue uploads).
pub struct RoutingExportSink {
    pub store: Arc<SessionStore>,
    pub photos: Arc<dyn PhotoLibrary>,
    /// Where `Files` and `Share` exports go (`<root>/<session>/…`).
    pub exports_root: PathBuf,
}

impl RoutingExportSink {
    async fn deliver_photos(
        &self,
        file: &Path,
        item: &ExportItem,
    ) -> tether_library::Result<Option<String>> {
        // Sidecars and manifests have no place in Photos.
        if item.is_companion {
            return Ok(None);
        }
        if !self.photos.request_add_only().await {
            return Err(delivery(crate::platform::photos::NOT_AUTHORIZED));
        }
        self.photos.add_image(file).await.map_err(delivery)
    }

    fn deliver_files(
        &self,
        file: &Path,
        item: &ExportItem,
        share: bool,
    ) -> tether_library::Result<Option<String>> {
        let mut dir = self
            .exports_root
            .join(session_folder_name(&self.store, item));
        if share {
            dir = dir.join("Share");
        }
        let relative = item.delivered_relative_path();
        let rel = Path::new(&relative);
        if let Some(sub) = rel.parent().filter(|p| !p.as_os_str().is_empty()) {
            dir = dir.join(sub);
        }
        std::fs::create_dir_all(&dir)?;
        let preferred = rel
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| {
                file.file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string()
            });
        let target = unique_path(&dir, &preferred);
        std::fs::copy(file, &target)?;
        Ok(Some(target.to_string_lossy().to_string()))
    }

    fn folder_root(&self, destination: &ExportDestination) -> tether_library::Result<PathBuf> {
        let ExportDestination::Folder { destination_id } = destination else {
            return Err(delivery("The export folder is not reachable."));
        };
        let name = self
            .store
            .folder_destination(destination_id)?
            .map(|d| d.name)
            .unwrap_or_else(|| "The export folder".into());
        let root = folder_path(&self.store, destination_id).filter(|p| p.is_dir());
        root.ok_or_else(|| {
            delivery(format!(
                "{name} is not reachable. Reconnect the drive or server, or pick the folder again."
            ))
        })
    }
}

#[async_trait::async_trait]
impl ExportSink for RoutingExportSink {
    async fn deliver(
        &self,
        file: &Path,
        item: &ExportItem,
        destination: &ExportDestination,
    ) -> tether_library::Result<Option<String>> {
        match destination {
            ExportDestination::Photos => self.deliver_photos(file, item).await,
            ExportDestination::Files => self.deliver_files(file, item, false),
            ExportDestination::Share => self.deliver_files(file, item, true),
            ExportDestination::Folder { .. } => {
                let root = self.folder_root(destination)?;
                let relative = item.delivered_relative_path();
                let relative = if relative.is_empty() {
                    file.file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .to_string()
                } else {
                    relative
                };
                let target = place(file, &relative, &root)?;
                Ok(Some(target.to_string_lossy().to_string()))
            }
            // Handled inside the export queue.
            ExportDestination::Ftp { .. } => Ok(None),
        }
    }

    async fn prepare_directories(
        &self,
        directories: &[String],
        destination: &ExportDestination,
    ) -> tether_library::Result<()> {
        if let ExportDestination::Folder { .. } = destination {
            let root = self.folder_root(destination)?;
            for d in directories {
                let _ = std::fs::create_dir_all(root.join(d));
            }
        }
        Ok(())
    }
}

/// The FTP client settings for a saved destination (password from the Keychain).
pub fn ftp_destination(stored: &StoredFtpDestination, secrets: &dyn SecretStore) -> FtpDestination {
    FtpDestination {
        host: stored.host.clone(),
        port: stored.port,
        username: stored.username.clone(),
        password: secrets
            .read(&stored.password_keychain_key)
            .unwrap_or_default(),
        security: serde_json::from_str(&format!("\"{}\"", stored.security))
            .unwrap_or(FtpSecurity::ExplicitTls),
        passive: stored.passive,
        remote_directory: stored.remote_directory.clone(),
    }
}

/// Uploads through `tether-net`'s FTP/FTPS client.
pub struct FtpUploader {
    pub client: FtpClient,
}

#[async_trait::async_trait]
impl Uploader for FtpUploader {
    async fn upload(&self, data: Vec<u8>, remote_path: &str) -> tether_library::Result<()> {
        self.client
            .upload(&data, remote_path, None)
            .await
            .map_err(delivery)
    }
}

/// Builds an [`FtpUploader`] per saved destination.
pub struct FtpUploaderFactory {
    pub secrets: Arc<dyn SecretStore>,
}

impl UploaderFactory for FtpUploaderFactory {
    fn uploader(&self, destination: &StoredFtpDestination) -> Option<Arc<dyn Uploader>> {
        let d = ftp_destination(destination, self.secrets.as_ref());
        Some(Arc::new(FtpUploader {
            client: FtpClient::new(d),
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn place_replaces_and_unique_path_suffixes() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("a.jpg");
        std::fs::write(&src, b"one").unwrap();
        let root = dir.path().join("out");
        let t = place(&src, "Selects/a.jpg", &root).unwrap();
        assert_eq!(std::fs::read(&t).unwrap(), b"one");
        std::fs::write(&src, b"two").unwrap();
        place(&src, "Selects/a.jpg", &root).unwrap();
        assert_eq!(std::fs::read(&t).unwrap(), b"two");
        let u = unique_path(&root.join("Selects"), "a.jpg");
        assert!(u.ends_with("a-1.jpg"));
    }
}
