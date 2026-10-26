//! The capture file store (`Capture/CaptureCacheProxy.swift`).
//!
//! Owns the bytes of every capture: originals under
//! `<root>/<session>/originals/`, proxies under `proxies/`, thumbnails under
//! `thumbs/`, plus a small in-memory LRU of recently requested files so the
//! filmstrip and loupe never hit disk twice in a row.
//!
//! Every path handed out is *relative* to the storage root and validated on
//! every read and write (no `..`, no absolute paths, no empty components).

use std::collections::{HashMap, VecDeque};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use tether_library::delivery::CaptureFiles;
use tether_library::ShootSession;

use crate::error::{lock, Error, Result};

#[derive(Default)]
struct Lru {
    map: HashMap<String, Vec<u8>>,
    order: VecDeque<String>,
    used: usize,
}

impl Lru {
    fn evict(&mut self, path: &str) {
        if let Some(d) = self.map.remove(path) {
            self.used -= d.len();
            self.order.retain(|p| p != path);
        }
    }

    fn touch(&mut self, path: &str) {
        if let Some(i) = self.order.iter().position(|p| p == path) {
            let p = self.order.remove(i).unwrap_or_default();
            self.order.push_back(p);
        }
    }
}

pub struct CaptureCacheProxy {
    storage_root: PathBuf,
    memory_budget: usize,
    lru: Mutex<Lru>,
}

impl std::fmt::Debug for CaptureCacheProxy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CaptureCacheProxy")
            .field("storage_root", &self.storage_root)
            .finish_non_exhaustive()
    }
}

/// Everything before the last `.` (Swift `deletingPathExtension`).
pub(crate) fn delete_extension(name: &str) -> &str {
    match name.rfind('.') {
        Some(i) if i > 0 && !name[..i].ends_with('/') => &name[..i],
        _ => name,
    }
}

/// The extension after the last `.` of the last component, or "".
pub(crate) fn extension(name: &str) -> &str {
    let last = name.rsplit('/').next().unwrap_or(name);
    match last.rfind('.') {
        Some(i) if i > 0 => &last[i + 1..],
        _ => "",
    }
}

impl CaptureCacheProxy {
    /// 96 MiB of recently used files stay in memory.
    pub const DEFAULT_MEMORY_BUDGET: usize = 96 << 20;

    pub fn new(storage_root: impl Into<PathBuf>) -> Self {
        Self::with_budget(storage_root, Self::DEFAULT_MEMORY_BUDGET)
    }

    pub fn with_budget(storage_root: impl Into<PathBuf>, memory_budget: usize) -> Self {
        let storage_root = storage_root.into();
        let _ = fs::create_dir_all(&storage_root);
        Self {
            storage_root,
            memory_budget,
            lru: Mutex::new(Lru::default()),
        }
    }

    pub fn storage_root(&self) -> &Path {
        &self.storage_root
    }

    // MARK: Paths

    pub fn validate(relative: &str) -> Result<&str> {
        let bad = relative.is_empty()
            || relative.starts_with('/')
            || relative.contains('\\')
            || relative.contains('\0')
            || relative.split('/').any(|c| c == ".." || c.is_empty());
        if bad {
            Err(Error::InvalidPath(relative.to_string()))
        } else {
            Ok(relative)
        }
    }

    /// Absolute path for a validated relative one.
    pub fn url(&self, relative: &str) -> Result<PathBuf> {
        Ok(self.storage_root.join(Self::validate(relative)?))
    }

    pub fn original_path(&self, session: &ShootSession, filename: &str) -> String {
        format!(
            "{}/originals/{}",
            session.directory_name(),
            Self::safe_filename(filename)
        )
    }

    pub fn proxy_path(&self, session: &ShootSession, filename: &str) -> String {
        format!(
            "{}/proxies/{}.jpg",
            session.directory_name(),
            delete_extension(&Self::safe_filename(filename))
        )
    }

    pub fn thumbnail_path(&self, session: &ShootSession, filename: &str) -> String {
        format!(
            "{}/thumbs/{}.jpg",
            session.directory_name(),
            delete_extension(&Self::safe_filename(filename))
        )
    }

    /// The last path component with `..` neutralised; never empty.
    pub fn safe_filename(name: &str) -> String {
        let last = name
            .trim_end_matches('/')
            .rsplit('/')
            .next()
            .unwrap_or_default();
        let s = last.replace("..", "_");
        if s.is_empty() || s == "." {
            "capture".into()
        } else {
            s
        }
    }

    // MARK: Writes

    /// Writes atomically; a name collision gets a numeric suffix so bursts
    /// from a reset camera counter never overwrite. Returns the path used.
    pub fn store(&self, data: &[u8], relative: &str) -> Result<String> {
        let mut path = Self::validate(relative)?.to_string();
        let mut url = self.url(&path)?;
        if let Some(dir) = url.parent() {
            fs::create_dir_all(dir)?;
        }
        let mut n = 1;
        while url.exists() {
            let original = Self::validate(relative)?;
            let ext = extension(original);
            let base = if ext.is_empty() {
                original
            } else {
                &original[..original.len() - ext.len() - 1]
            };
            path = if ext.is_empty() {
                format!("{base}-{n}")
            } else {
                format!("{base}-{n}.{ext}")
            };
            url = self.url(&path)?;
            n += 1;
        }
        let tmp = url.with_file_name(format!(
            ".{}.{}.tmp",
            url.file_name().unwrap_or_default().to_string_lossy(),
            uuid::Uuid::new_v4().simple()
        ));
        fs::write(&tmp, data)?;
        if let Err(e) = fs::rename(&tmp, &url) {
            let _ = fs::remove_file(&tmp);
            return Err(e.into());
        }
        self.remember(&path, data);
        Ok(path)
    }

    /// Streamed write for large originals: chunks go to `<path>.part`, which
    /// is renamed into place on `finish`.
    pub fn writer(&self, relative: &str) -> Result<CacheWriter> {
        let url = self.url(relative)?;
        if let Some(dir) = url.parent() {
            fs::create_dir_all(dir)?;
        }
        let mut part = url.clone().into_os_string();
        part.push(".part");
        let part = PathBuf::from(part);
        let file = fs::File::create(&part)?;
        Ok(CacheWriter {
            file: Some(file),
            part,
            target: url,
            bytes: 0,
        })
    }

    // MARK: Reads

    pub fn load(&self, relative: &str) -> Result<Vec<u8>> {
        let path = Self::validate(relative)?;
        {
            let mut lru = lock(&self.lru);
            if let Some(d) = lru.map.get(path).cloned() {
                lru.touch(path);
                return Ok(d);
            }
        }
        let url = self.url(path)?;
        if !url.exists() {
            return Err(Error::NotFound(path.to_string()));
        }
        let d = fs::read(&url)?;
        self.remember(path, &d);
        Ok(d)
    }

    pub fn exists(&self, relative: &str) -> bool {
        self.url(relative).map(|u| u.exists()).unwrap_or(false)
    }

    pub fn size(&self, relative: &str) -> Option<u64> {
        let u = self.url(relative).ok()?;
        fs::metadata(u).ok().map(|m| m.len())
    }

    pub fn remove(&self, relative: &str) {
        if let Ok(u) = self.url(relative) {
            let _ = fs::remove_file(u);
        }
        lock(&self.lru).evict(relative);
    }

    pub fn remove_session(&self, session: &ShootSession) {
        let dir = session.directory_name();
        let _ = fs::remove_dir_all(self.storage_root.join(&dir));
        let prefix = format!("{dir}/");
        let mut lru = lock(&self.lru);
        let keys: Vec<String> = lru
            .map
            .keys()
            .filter(|k| k.starts_with(&prefix))
            .cloned()
            .collect();
        for k in keys {
            lru.evict(&k);
        }
    }

    /// Bytes on disk for a session's folder.
    pub fn session_bytes(&self, session: &ShootSession) -> u64 {
        fn walk(dir: &Path) -> u64 {
            let Ok(rd) = fs::read_dir(dir) else { return 0 };
            rd.flatten()
                .map(|e| match e.file_type() {
                    Ok(t) if t.is_dir() => walk(&e.path()),
                    Ok(t) if t.is_file() => e.metadata().map(|m| m.len()).unwrap_or(0),
                    _ => 0,
                })
                .sum()
        }
        walk(&self.storage_root.join(session.directory_name()))
    }

    /// Bytes held in the in-memory LRU.
    pub fn cached_bytes(&self) -> usize {
        lock(&self.lru).used
    }

    fn remember(&self, path: &str, data: &[u8]) {
        if data.len() > self.memory_budget / 4 {
            return;
        }
        let mut lru = lock(&self.lru);
        lru.evict(path);
        lru.map.insert(path.to_string(), data.to_vec());
        lru.order.push_back(path.to_string());
        lru.used += data.len();
        while lru.used > self.memory_budget {
            let Some(oldest) = lru.order.front().cloned() else {
                break;
            };
            lru.evict(&oldest);
        }
    }
}

impl CaptureFiles for CaptureCacheProxy {
    fn path_for(&self, relative: &str) -> tether_library::Result<PathBuf> {
        self.url(relative)
            .map_err(|_| tether_library::Error::InvalidPath(relative.to_string()))
    }
}

/// A streamed write into the cache (see [`CaptureCacheProxy::writer`]).
pub struct CacheWriter {
    file: Option<fs::File>,
    part: PathBuf,
    target: PathBuf,
    bytes: usize,
}

impl CacheWriter {
    pub fn bytes(&self) -> usize {
        self.bytes
    }

    pub fn append(&mut self, chunk: &[u8]) -> Result<()> {
        let f = self
            .file
            .as_mut()
            .ok_or_else(|| Error::msg("The writer is already finished."))?;
        f.write_all(chunk)?;
        self.bytes += chunk.len();
        Ok(())
    }

    pub fn finish(mut self) -> Result<()> {
        let Some(mut f) = self.file.take() else {
            return Ok(());
        };
        f.flush()?;
        drop(f);
        if self.target.exists() {
            fs::remove_file(&self.target)?;
        }
        fs::rename(&self.part, &self.target)?;
        Ok(())
    }

    pub fn abort(mut self) {
        self.file.take();
        let _ = fs::remove_file(&self.part);
    }
}

impl Drop for CacheWriter {
    fn drop(&mut self) {
        if self.file.take().is_some() {
            let _ = fs::remove_file(&self.part);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_cache() -> (tempfile::TempDir, CaptureCacheProxy) {
        let dir = tempfile::tempdir().unwrap();
        let cache = CaptureCacheProxy::with_budget(dir.path().join("root"), 1024);
        (dir, cache)
    }

    #[test]
    fn paths_are_validated_and_relative() {
        let (_d, cache) = make_cache();
        assert!(cache.url("../etc/passwd").is_err());
        assert!(cache.url("/abs").is_err());
        assert!(cache.url("a//b").is_err());
        assert!(cache.url("s/originals/a.jpg").is_ok());
        let s = ShootSession::new("x");
        assert_eq!(
            cache.original_path(&s, "../../IMG.JPG"),
            format!("{}/originals/IMG.JPG", s.directory_name())
        );
        assert_eq!(
            cache.proxy_path(&s, "IMG_1.CR3"),
            format!("{}/proxies/IMG_1.jpg", s.directory_name())
        );
    }

    #[test]
    fn store_load_collision_and_lru() {
        let (_d, cache) = make_cache();
        let s = ShootSession::new("x");
        let p1 = cache
            .store(&[1, 2, 3], &cache.original_path(&s, "A.JPG"))
            .unwrap();
        let p2 = cache
            .store(&[4], &cache.original_path(&s, "A.JPG"))
            .unwrap();
        assert_ne!(p1, p2);
        assert!(p2.ends_with("A-1.JPG"));
        assert_eq!(cache.load(&p1).unwrap(), vec![1, 2, 3]);
        assert_eq!(cache.size(&p2), Some(1));
        cache
            .store(
                &vec![7; 2048],
                &format!("{}/originals/big.bin", s.directory_name()),
            )
            .unwrap();
        assert!(cache.cached_bytes() <= 1024);
        assert_eq!(cache.session_bytes(&s), 3 + 1 + 2048);
        cache.remove_session(&s);
        assert!(!cache.exists(&p1));
        assert!(cache.load(&p1).is_err());
    }

    #[test]
    fn streaming_writer() {
        let (_d, cache) = make_cache();
        let mut w = cache.writer("s/originals/stream.bin").unwrap();
        w.append(&[1, 2]).unwrap();
        w.append(&[3]).unwrap();
        w.finish().unwrap();
        assert_eq!(cache.load("s/originals/stream.bin").unwrap(), vec![1, 2, 3]);
        assert!(!cache.exists("s/originals/stream.bin.part"));
    }
}
