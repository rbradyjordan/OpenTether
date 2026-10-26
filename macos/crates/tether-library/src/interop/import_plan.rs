//! Turning a pile of files into captures to import (`Interop/FileImportPlan.swift`).

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use crate::capture_item::MediaKind;
use crate::util;

/// One file to import, with its XMP sidecar when one sits beside it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportEntry {
    pub file: PathBuf,
    pub sidecar: Option<PathBuf>,
}

/// Turns files (picked one by one, or every file under a folder) into
/// captures to import, each with its XMP sidecar. Both sidecar spellings are
/// matched: `IMG_0001.xmp` (Lightroom, Capture One, Photo Mechanic) and
/// `IMG_0001.CR3.xmp` (darktable, some DAMs). Hidden files, manifests,
/// catalogs and anything that is not a still or a video are left out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileImportPlan {
    pub entries: Vec<ImportEntry>,
    /// Files that were neither importable media nor a matched sidecar.
    pub skipped: Vec<PathBuf>,
}

fn file_name(p: &Path) -> String {
    p.file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default()
}

/// Folder + upper-cased name: the match key for a file and its sidecar.
fn key(dir: &Path, name: &str) -> String {
    format!(
        "{}/{}",
        dir.to_string_lossy().trim_end_matches('/'),
        name.to_uppercase()
    )
}

impl FileImportPlan {
    pub fn new(files: &[PathBuf]) -> Self {
        let mut sidecars: HashMap<String, PathBuf> = HashMap::new();
        let mut media: Vec<PathBuf> = Vec::new();
        let mut skipped: Vec<PathBuf> = Vec::new();
        for path in files {
            let name = file_name(path);
            if name.starts_with('.') {
                continue;
            }
            let dir = path.parent().unwrap_or(Path::new(""));
            let ext = util::path_extension(&name).to_lowercase();
            if ext == "xmp" {
                // Key by the full stem, which for "IMG.CR3.xmp" is "IMG.CR3".
                sidecars.insert(key(dir, util::delete_path_extension(&name)), path.clone());
                continue;
            }
            if MediaKind::from_filename(&name) == MediaKind::Other {
                skipped.push(path.clone());
            } else {
                media.push(path.clone());
            }
        }
        media.sort_by(|a, b| util::natural_cmp(&file_name(a), &file_name(b)));
        let mut used: HashSet<PathBuf> = HashSet::new();
        let mut entries = Vec::new();
        for path in media {
            let name = file_name(&path);
            let dir = path.parent().unwrap_or(Path::new(""));
            let sidecar = sidecars
                .get(&key(dir, &name))
                .or_else(|| sidecars.get(&key(dir, util::delete_path_extension(&name))))
                .cloned();
            if let Some(s) = &sidecar {
                used.insert(s.clone());
            }
            entries.push(ImportEntry {
                file: path,
                sidecar,
            });
        }
        let mut orphans: Vec<PathBuf> = sidecars
            .into_values()
            .filter(|s| !used.contains(s))
            .collect();
        orphans.sort();
        skipped.extend(orphans);
        Self { entries, skipped }
    }

    /// Every regular file under `folder` (recursively), skipping hidden
    /// entries and the insides of packages, for a folder import.
    pub fn files_under(folder: &Path) -> Vec<PathBuf> {
        const PACKAGES: [&str; 12] = [
            "app",
            "bundle",
            "framework",
            "plugin",
            "cocatalog",
            "photoslibrary",
            "lrlibrary",
            "lrdata",
            "fcpbundle",
            "rtfd",
            "pages",
            "key",
        ];
        let mut out = Vec::new();
        let mut stack = vec![folder.to_path_buf()];
        while let Some(dir) = stack.pop() {
            let Ok(read) = std::fs::read_dir(&dir) else {
                continue;
            };
            for entry in read.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                if name.starts_with('.') {
                    continue;
                }
                let Ok(ft) = entry.file_type() else { continue };
                let path = entry.path();
                if ft.is_dir() {
                    let ext = util::path_extension(&name).to_lowercase();
                    if !PACKAGES.contains(&ext.as_str()) {
                        stack.push(path);
                    }
                } else if ft.is_file() {
                    out.push(path);
                }
            }
        }
        out
    }
}
