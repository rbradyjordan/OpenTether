//! Exports: to a folder (security-scoped bookmark kept, path resolved by
//! the shell), to FTP (password in the Keychain), to Photos, to the app's
//! exports folder; export jobs, retry, pause; saved destinations.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use tether_library::delivery::{ExportDestination, ExportJob, ExportOptions};
use tether_library::library::memory::ExportMemory;
use tether_library::library::WorkspaceMemory;
use tether_library::looks::LookStack;
use tether_library::store::{StoredFolderDestination, StoredFtpDestination};
use tether_net::FtpClient;

use super::AppCore;
use crate::error::{Error, Result};
use crate::events::{ExportJobDto, ToastKind};
use crate::sinks::{folder_path, folder_path_key, ftp_destination};

/// One export: which captures, where, how.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportRequest {
    pub ids: Vec<String>,
    pub destination: ExportDestination,
    /// `None`: the last export's options.
    #[serde(default)]
    pub options: Option<ExportOptions>,
    /// `None`: each session's own look.
    #[serde(default)]
    pub look: Option<LookStack>,
}

/// A saved FTP upload target as the settings sheet edits it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FtpDestinationInput {
    /// `None` creates a new destination.
    #[serde(default)]
    pub id: Option<String>,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    /// `"plain"` | `"explicitTLS"` | `"implicitTLS"`.
    pub security: String,
    pub passive: bool,
    pub remote_directory: String,
    /// `None` keeps the stored password.
    #[serde(default)]
    pub password: Option<String>,
}

impl AppCore {
    /// Queue exports, one job per session (RAW skipped unless the options
    /// include it). Remembers destination and options for "Export again".
    pub fn export(&self, req: ExportRequest) -> Result<Vec<ExportJobDto>> {
        let memory = &self.inner.memory;
        let options = req
            .options
            .clone()
            .unwrap_or_else(|| memory.get(WorkspaceMemory::LAST_EXPORT).options);
        let items = self.inner.store.captures_by_ids(&req.ids)?;
        if items.is_empty() {
            self.toast("Nothing to export", ToastKind::Info);
            return Ok(Vec::new());
        }
        let mut by_session: BTreeMap<String, Vec<_>> = BTreeMap::new();
        for c in items {
            by_session.entry(c.session_id.clone()).or_default().push(c);
        }
        let mut jobs: Vec<ExportJob> = Vec::new();
        for (session_id, group) in by_session {
            let Ok(session) = self.load_session(&session_id) else {
                continue;
            };
            let look = req
                .look
                .clone()
                .unwrap_or_else(|| LookStack::new(session.look_id.clone(), session.look_strength));
            let job = self.inner.queue.make_job(
                &session,
                &group,
                req.destination.clone(),
                options.clone(),
                look,
            );
            if job.items.is_empty() {
                continue;
            }
            self.inner.queue.enqueue(&job)?;
            jobs.push(job);
        }
        let mut last = memory.get(WorkspaceMemory::LAST_EXPORT);
        last.destination = req.destination.clone();
        last.options = options;
        memory.set(WorkspaceMemory::LAST_EXPORT, &last);
        if let ExportDestination::Ftp { destination_id } = &req.destination {
            memory.note_ftp(destination_id);
        }
        let queued: usize = jobs
            .iter()
            .map(|j| j.items.iter().filter(|i| !i.is_companion).count())
            .sum();
        if queued > 0 {
            self.toast(
                format!("Exporting {queued} to {}", req.destination.display_name()),
                ToastKind::Info,
            );
        } else {
            self.toast("Nothing to export", ToastKind::Info);
        }
        Ok(jobs.iter().map(ExportJobDto::from).collect())
    }

    /// The last destination and options again.
    pub fn export_again(&self, ids: &[String]) -> Result<Vec<ExportJobDto>> {
        let last: ExportMemory = self.inner.memory.get(WorkspaceMemory::LAST_EXPORT);
        self.export(ExportRequest {
            ids: ids.to_vec(),
            destination: last.destination,
            options: Some(last.options),
            look: None,
        })
    }

    /// Export into a folder the user picked. The shell resolves the
    /// security-scoped bookmark and passes the path; the bookmark is kept
    /// with the destination so the shell can resolve it next launch.
    pub fn export_to_folder(
        &self,
        ids: &[String],
        path: &Path,
        bookmark: Option<Vec<u8>>,
        options: Option<ExportOptions>,
    ) -> Result<Vec<ExportJobDto>> {
        let folder = self.add_folder_destination(path, bookmark)?;
        self.export(ExportRequest {
            ids: ids.to_vec(),
            destination: ExportDestination::Folder {
                destination_id: folder.id,
            },
            options,
            look: None,
        })
    }

    pub fn export_to_ftp(
        &self,
        ids: &[String],
        destination_id: &str,
        options: Option<ExportOptions>,
    ) -> Result<Vec<ExportJobDto>> {
        self.export(ExportRequest {
            ids: ids.to_vec(),
            destination: ExportDestination::Ftp {
                destination_id: destination_id.to_string(),
            },
            options,
            look: None,
        })
    }

    /// Export into the Photos library (add-only access is requested on
    /// the first delivery).
    pub fn export_to_photos(
        &self,
        ids: &[String],
        options: Option<ExportOptions>,
    ) -> Result<Vec<ExportJobDto>> {
        self.export(ExportRequest {
            ids: ids.to_vec(),
            destination: ExportDestination::Photos,
            options,
            look: None,
        })
    }

    pub fn export_jobs(&self, session_id: Option<&str>) -> Result<Vec<ExportJobDto>> {
        Ok(self
            .inner
            .queue
            .jobs(session_id)?
            .iter()
            .map(ExportJobDto::from)
            .collect())
    }

    /// Re-run a job's failed items.
    pub fn retry_export(&self, job_id: &str) -> Result<()> {
        Ok(self.inner.queue.retry(job_id)?)
    }

    pub fn pause_exports(&self) {
        self.inner.queue.pause();
    }

    pub fn resume_exports(&self) {
        self.inner.queue.resume();
    }

    /// Where `Files` exports land.
    pub fn exports_root(&self) -> PathBuf {
        self.inner.exports_root.clone()
    }

    // MARK: Folder destinations

    /// Saves (or refreshes) a picked folder: recognises a Capture One
    /// session root, keeps the bookmark, remembers the resolved path.
    pub fn add_folder_destination(
        &self,
        path: &Path,
        bookmark: Option<Vec<u8>>,
    ) -> Result<StoredFolderDestination> {
        if !path.is_dir() {
            return Err(Error::msg("That isn't a folder."));
        }
        let store = &self.inner.store;
        let existing = store
            .folder_destinations()?
            .into_iter()
            .find(|d| folder_path(store, &d.id).as_deref() == Some(path));
        let entries: Vec<String> = std::fs::read_dir(path)
            .map(|rd| {
                rd.flatten()
                    .map(|e| e.file_name().to_string_lossy().to_string())
                    .collect()
            })
            .unwrap_or_default();
        let kind = StoredFolderDestination::detect_kind(&entries);
        let mut d = match existing {
            Some(mut d) => {
                d.kind = kind;
                if let Some(b) = bookmark {
                    d.bookmark = b;
                }
                d
            }
            None => StoredFolderDestination::new(
                path.file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_else(|| path.display().to_string()),
                bookmark.unwrap_or_default(),
                kind,
            ),
        };
        d.display_path = Some(display_path(path));
        store.save_folder_destination(&d)?;
        store.set_setting(&folder_path_key(&d.id), Some(&path.to_string_lossy()));
        Ok(d)
    }

    /// The shell re-resolved a stale bookmark: store the fresh path (and
    /// bookmark).
    pub fn update_folder_path(
        &self,
        id: &str,
        path: &Path,
        bookmark: Option<Vec<u8>>,
    ) -> Result<()> {
        let store = &self.inner.store;
        let mut d = store
            .folder_destination(id)?
            .ok_or_else(|| Error::NotFound(format!("Folder {id}")))?;
        if let Some(b) = bookmark {
            d.bookmark = b;
        }
        d.display_path = Some(display_path(path));
        store.save_folder_destination(&d)?;
        store.set_setting(&folder_path_key(id), Some(&path.to_string_lossy()));
        Ok(())
    }

    pub fn folder_destinations(&self) -> Result<Vec<StoredFolderDestination>> {
        Ok(self.inner.store.folder_destinations()?)
    }

    pub fn delete_folder_destination(&self, id: &str) -> Result<()> {
        self.inner.store.delete_folder_destination(id)?;
        self.inner.store.set_setting(&folder_path_key(id), None);
        Ok(())
    }

    // MARK: FTP destinations

    pub fn ftp_destinations(&self) -> Result<Vec<StoredFtpDestination>> {
        Ok(self.inner.store.ftp_destinations()?)
    }

    /// Saves a destination; the password goes to the Keychain.
    pub fn save_ftp_destination(&self, input: FtpDestinationInput) -> Result<StoredFtpDestination> {
        let mut d = match input.id.as_deref() {
            Some(id) => self
                .inner
                .store
                .ftp_destinations()?
                .into_iter()
                .find(|d| d.id == id)
                .ok_or_else(|| Error::NotFound(format!("FTP destination {id}")))?,
            None => StoredFtpDestination::new(&input.name, &input.host, &input.username),
        };
        d.name = input.name;
        d.host = input.host.trim().to_string();
        d.port = input.port;
        d.username = input.username;
        d.security = input.security;
        d.passive = input.passive;
        d.remote_directory = if input.remote_directory.is_empty() {
            "/".into()
        } else {
            input.remote_directory
        };
        self.inner.store.save_ftp_destination(&d)?;
        if let Some(p) = input.password {
            self.inner.secrets.write(&d.password_keychain_key, Some(&p));
        }
        Ok(d)
    }

    pub fn delete_ftp_destination(&self, id: &str) -> Result<()> {
        if let Some(d) = self
            .inner
            .store
            .ftp_destinations()?
            .into_iter()
            .find(|d| d.id == id)
        {
            self.inner.secrets.write(&d.password_keychain_key, None);
        }
        Ok(self.inner.store.delete_ftp_destination(id)?)
    }

    /// Connect and log in; returns the server's banner and features.
    pub async fn test_ftp_destination(&self, id: &str) -> Result<String> {
        let d = self
            .inner
            .store
            .ftp_destinations()?
            .into_iter()
            .find(|d| d.id == id)
            .ok_or_else(|| Error::NotFound(format!("FTP destination {id}")))?;
        let client = FtpClient::new(ftp_destination(&d, self.inner.secrets.as_ref()));
        client.test().await.map_err(|e| Error::msg(e.to_string()))
    }
}

/// "Pictures › Shoots › AW26" style path for display.
fn display_path(path: &Path) -> String {
    let parts: Vec<String> = path
        .components()
        .map(|c| c.as_os_str().to_string_lossy().to_string())
        .filter(|c| c != "/")
        .collect();
    if let Some(i) = parts.iter().position(|p| p == "com~apple~CloudDocs") {
        let mut v = vec!["iCloud Drive".to_string()];
        v.extend(parts[i + 1..].iter().cloned());
        return v.join(" › ");
    }
    let n = parts.len();
    parts[n.saturating_sub(3)..].join(" › ")
}
