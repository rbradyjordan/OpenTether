//! Virtual-path sandboxing for the FTP server and `ls -l`-style listings.
//! Clients see a "/"-rooted tree; every path is normalized lexically and any
//! attempt to climb above the root is rejected (`None` → 550). On top of the
//! Swift rules, the on-disk mapping refuses to walk through symlinks, so a
//! link inside the root can never lead outside it. Ported from `FTPPath.swift`.

use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};

pub struct FtpPath;

impl FtpPath {
    /// Resolves `argument` against `cwd` (both virtual, "/"-rooted).
    pub fn resolve(argument: &str, cwd: &str) -> Option<String> {
        let mut stack: Vec<String> = if argument.starts_with('/') {
            Vec::new()
        } else {
            Self::components(cwd)
        };
        for part in argument.split('/').filter(|p| !p.is_empty()) {
            match part {
                "." => continue,
                ".." => {
                    stack.pop()?;
                }
                _ => {
                    if part.contains('\0') || part.contains('\\') {
                        return None;
                    }
                    stack.push(part.to_string());
                }
            }
        }
        Some(format!("/{}", stack.join("/")))
    }

    pub fn components(virtual_path: &str) -> Vec<String> {
        virtual_path
            .split('/')
            .filter(|p| !p.is_empty())
            .map(str::to_string)
            .collect()
    }

    /// Parent of a virtual path ("/" for top-level entries).
    pub fn parent(virtual_path: &str) -> String {
        let mut c = Self::components(virtual_path);
        c.pop();
        format!("/{}", c.join("/"))
    }

    pub fn name(virtual_path: &str) -> String {
        Self::components(virtual_path).pop().unwrap_or_default()
    }

    /// On-disk path for a *resolved* virtual path (lexical only).
    pub fn file_path(root: &Path, virtual_path: &str) -> PathBuf {
        let mut p = root.to_path_buf();
        for c in Self::components(virtual_path) {
            p.push(c);
        }
        p
    }

    /// Like [`file_path`](Self::file_path), but `None` when any existing
    /// component below `root` is a symlink, or a component is not a plain
    /// name (defence in depth on top of [`resolve`](Self::resolve)).
    pub fn sandboxed(root: &Path, virtual_path: &str) -> Option<PathBuf> {
        let mut p = root.to_path_buf();
        for c in Self::components(virtual_path) {
            if c == "." || c == ".." || c.contains('\0') || c.contains('\\') {
                return None;
            }
            p.push(&c);
            if let Ok(meta) = std::fs::symlink_metadata(&p) {
                if meta.file_type().is_symlink() {
                    return None;
                }
            }
        }
        Some(p)
    }
}

/// One directory entry for LIST/NLST.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FtpListingEntry {
    pub name: String,
    pub is_directory: bool,
    pub size: u64,
    pub modified: DateTime<Utc>,
}

/// `ls -l`-style lines for LIST, and the bare names for NLST.
pub struct FtpListing;

impl FtpListing {
    pub fn line(e: &FtpListingEntry, now: DateTime<Utc>) -> String {
        let perms = if e.is_directory {
            "drwxr-xr-x"
        } else {
            "-rw-r--r--"
        };
        let six_months = chrono::TimeDelta::days(182);
        let age = (now - e.modified).abs();
        let stamp = if age < six_months {
            e.modified.format("%b %d %H:%M").to_string()
        } else {
            e.modified.format("%b %d  %Y").to_string()
        };
        format!("{perms} 1 tether tether {:>12} {stamp} {}", e.size, e.name)
    }

    /// `YYYYMMDDhhmmss` in UTC, as MDTM wants.
    pub fn mdtm_string(date: DateTime<Utc>) -> String {
        date.format("%Y%m%d%H%M%S").to_string()
    }

    /// Entries of `directory`, sorted by name; unreadable entries are skipped.
    pub async fn entries(directory: &Path) -> Vec<FtpListingEntry> {
        let Ok(mut rd) = tokio::fs::read_dir(directory).await else {
            return Vec::new();
        };
        let mut out = Vec::new();
        while let Ok(Some(entry)) = rd.next_entry().await {
            let Ok(meta) = tokio::fs::symlink_metadata(entry.path()).await else {
                continue;
            };
            let modified = meta
                .modified()
                .map(DateTime::<Utc>::from)
                .unwrap_or_else(|_| Utc::now());
            out.push(FtpListingEntry {
                name: entry.file_name().to_string_lossy().into_owned(),
                is_directory: meta.is_dir(),
                size: meta.len(),
                modified,
            });
        }
        out.sort_by(|a, b| a.name.cmp(&b.name));
        out
    }

    /// Parses one of our own lines back (used by tests).
    pub fn parse_line(line: &str) -> Option<(String, bool, u64)> {
        let parts: Vec<&str> = line.split(' ').filter(|p| !p.is_empty()).collect();
        if parts.len() < 9 {
            return None;
        }
        let size = parts[4].parse().ok()?;
        Some((parts[8..].join(" "), parts[0].starts_with('d'), size))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn resolve_normalizes() {
        let r = |a, c| FtpPath::resolve(a, c);
        assert_eq!(r("IMG_0001.JPG", "/").as_deref(), Some("/IMG_0001.JPG"));
        assert_eq!(r("2026/10/16", "/").as_deref(), Some("/2026/10/16"));
        assert_eq!(r("16", "/2026/10").as_deref(), Some("/2026/10/16"));
        assert_eq!(r("/abs/./x//y/", "/ignored").as_deref(), Some("/abs/x/y"));
        assert_eq!(r("..", "/a/b").as_deref(), Some("/a"));
        assert_eq!(r("../c", "/a/b").as_deref(), Some("/a/c"));
        assert_eq!(r("", "/a").as_deref(), Some("/a"));
        assert_eq!(r(".", "/a").as_deref(), Some("/a"));
    }

    #[test]
    fn resolve_rejects_escapes() {
        assert_eq!(FtpPath::resolve("..", "/"), None);
        assert_eq!(FtpPath::resolve("../../etc/passwd", "/a"), None);
        assert_eq!(FtpPath::resolve("/../x", "/deep/dir"), None);
        assert_eq!(FtpPath::resolve("a/../../..", "/x"), None);
        assert_eq!(FtpPath::resolve("bad\0name", "/"), None);
        assert_eq!(FtpPath::resolve("win\\style", "/"), None);
    }

    #[test]
    fn parent_name_and_path() {
        assert_eq!(FtpPath::parent("/a/b/c.jpg"), "/a/b");
        assert_eq!(FtpPath::parent("/c.jpg"), "/");
        assert_eq!(FtpPath::parent("/"), "/");
        assert_eq!(FtpPath::name("/a/b/c.jpg"), "c.jpg");
        let root = Path::new("/tmp/root");
        assert_eq!(
            FtpPath::file_path(root, "/2026/x.jpg"),
            PathBuf::from("/tmp/root/2026/x.jpg")
        );
        assert_eq!(FtpPath::file_path(root, "/"), PathBuf::from("/tmp/root"));
    }

    #[cfg(unix)]
    #[test]
    fn sandbox_refuses_symlinks() {
        let dir = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::os::unix::fs::symlink(outside.path(), dir.path().join("link")).unwrap();
        assert!(FtpPath::sandboxed(dir.path(), "/link/x.jpg").is_none());
        assert!(FtpPath::sandboxed(dir.path(), "/link").is_none());
        assert_eq!(
            FtpPath::sandboxed(dir.path(), "/real/x.jpg"),
            Some(dir.path().join("real/x.jpg"))
        );
    }

    #[test]
    fn listing_line_round_trip() {
        let date = Utc.timestamp_opt(1_760_000_000, 0).unwrap(); // 2025-10-09 UTC
        let file = FtpListing::line(
            &FtpListingEntry {
                name: "IMG 0001.JPG".into(),
                is_directory: false,
                size: 1_048_576,
                modified: date,
            },
            date,
        );
        assert!(file.starts_with("-rw-r--r-- 1 tether tether "));
        assert!(file.contains("1048576 Oct 09 "));
        assert!(file.ends_with(" IMG 0001.JPG"));
        assert_eq!(
            FtpListing::parse_line(&file),
            Some(("IMG 0001.JPG".to_string(), false, 1_048_576))
        );
        let old = FtpListing::line(
            &FtpListingEntry {
                name: "2024".into(),
                is_directory: true,
                size: 4096,
                modified: date,
            },
            date + chrono::TimeDelta::days(400),
        );
        assert!(old.starts_with("drwxr-xr-x"));
        assert!(old.contains("Oct 09  2025"));
        assert_eq!(FtpListing::parse_line(&old).map(|p| p.1), Some(true));
        assert_eq!(FtpListing::parse_line("garbage"), None);
        assert_eq!(FtpListing::mdtm_string(date), "20251009085320");
    }
}
