//! Reading Lightroom Classic and Capture One catalogs back, read-only
//! (`Interop/Catalogs.swift`).
//!
//! Writing into a live catalog is not done: they are undocumented SQLite
//! databases the desktop app keeps open and migrates between versions. What
//! does work is the reverse direction: open a private copy of the catalog
//! read-only and bring the culling decisions made on the desktop (stars,
//! pick/reject, colour labels, keywords) back onto the captures here,
//! matched by file name.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

use rusqlite::Connection;

use crate::capture_item::{CaptureFlag, CaptureItem, ColorLabel};
use crate::store::database::{query_rows, Snapshot};
use crate::{util, Result};

/// One photo's culling state as a catalog records it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CatalogEntry {
    pub filename: String,
    pub folder: Option<String>,
    /// 0…5; `None` when the catalog has no rating for it.
    pub rating: Option<i64>,
    pub flag: Option<CaptureFlag>,
    pub label: Option<ColorLabel>,
    pub keywords: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CatalogKind {
    Lightroom,
    CaptureOne,
}

impl CatalogKind {
    pub fn display_name(self) -> &'static str {
        match self {
            Self::Lightroom => "Lightroom Classic catalog",
            Self::CaptureOne => "Capture One catalog",
        }
    }

    /// `.lrcat` → Lightroom; `.cocatalogdb` / `.cosessiondb` (or a
    /// `.cocatalog` package holding one) → Capture One.
    pub fn detect(path: &Path) -> Option<CatalogKind> {
        let ext = path.extension()?.to_string_lossy().to_lowercase();
        match ext.as_str() {
            "lrcat" => Some(Self::Lightroom),
            "cocatalogdb" | "cosessiondb" | "cocatalog" => Some(Self::CaptureOne),
            _ => None,
        }
    }

    /// The SQLite file inside a `.cocatalog` package (or the path itself).
    pub fn database_file(path: &Path) -> PathBuf {
        let is_package = path
            .extension()
            .is_some_and(|e| e.to_string_lossy().eq_ignore_ascii_case("cocatalog"));
        if !is_package {
            return path.to_path_buf();
        }
        std::fs::read_dir(path)
            .ok()
            .and_then(|rd| {
                rd.flatten().map(|e| e.path()).find(|p| {
                    p.extension()
                        .is_some_and(|e| e.to_string_lossy().eq_ignore_ascii_case("cocatalogdb"))
                })
            })
            .unwrap_or_else(|| path.to_path_buf())
    }

    /// Lightroom leaves `<name>.lrcat-lock` (and a WAL) beside a catalog it
    /// has open: what we read is then the last state Lightroom saved.
    pub fn is_open_elsewhere(path: &Path) -> bool {
        let with = |s: &str| {
            let mut p = path.as_os_str().to_os_string();
            p.push(s);
            PathBuf::from(p).exists()
        };
        with("-lock") || with("-wal")
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CatalogError {
    #[error("{0} is not a Lightroom or Capture One catalog.")]
    Unsupported(String),
    #[error("This {0} uses a layout Open Tether does not recognise yet.")]
    UnrecognisedSchema(String),
}

/// Read every photo's culling state from a catalog file (read-only).
pub fn read_entries(path: &Path) -> Result<Vec<CatalogEntry>> {
    let kind = CatalogKind::detect(path).ok_or_else(|| {
        CatalogError::Unsupported(
            path.file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default(),
        )
    })?;
    // The snapshot (and its temporary folder) goes away when it drops.
    let snapshot = Snapshot::of(&CatalogKind::database_file(path))?;
    match kind {
        CatalogKind::Lightroom => lightroom(snapshot.connection()),
        CatalogKind::CaptureOne => capture_one(snapshot.connection()),
    }
}

fn table_names(conn: &Connection) -> Result<Vec<String>> {
    Ok(query_rows(
        conn,
        "SELECT name FROM sqlite_master WHERE type = 'table'",
        &[],
    )?
    .into_iter()
    .filter_map(|r| r.string("name").map(str::to_string))
    .collect())
}

/// Lightroom Classic (`.lrcat`): Adobe_images (rating, pick, colorLabels) →
/// AgLibraryFile (baseName, extension) → AgLibraryFolder /
/// AgLibraryRootFolder; keywords through AgLibraryKeywordImage.
pub fn lightroom(conn: &Connection) -> Result<Vec<CatalogEntry>> {
    let tables: HashSet<String> = table_names(conn)?
        .into_iter()
        .map(|t| t.to_lowercase())
        .collect();
    if !tables.contains("adobe_images") || !tables.contains("aglibraryfile") {
        return Err(CatalogError::UnrecognisedSchema("Lightroom catalog".into()).into());
    }
    let has_folders = tables.contains("aglibraryfolder") && tables.contains("aglibraryrootfolder");
    let sql = format!(
        "SELECT i.id_local AS id, i.rating AS rating, i.pick AS pick, i.colorLabels AS label,
                f.baseName AS base, f.extension AS ext{}
         FROM Adobe_images i JOIN AgLibraryFile f ON f.id_local = i.rootFile
         {}",
        if has_folders {
            ", r.absolutePath AS root, d.pathFromRoot AS sub"
        } else {
            ""
        },
        if has_folders {
            "LEFT JOIN AgLibraryFolder d ON d.id_local = f.folder LEFT JOIN AgLibraryRootFolder r ON r.id_local = d.rootFolder"
        } else {
            ""
        }
    );
    let mut keywords: HashMap<i64, Vec<String>> = HashMap::new();
    if tables.contains("aglibrarykeywordimage") && tables.contains("aglibrarykeyword") {
        for row in query_rows(
            conn,
            "SELECT ki.image AS image, k.name AS name FROM AgLibraryKeywordImage ki JOIN AgLibraryKeyword k ON k.id_local = ki.tag",
            &[],
        )? {
            if let (Some(image), Some(name)) = (row.int("image"), row.string("name")) {
                if !name.is_empty() {
                    keywords.entry(image).or_default().push(name.to_string());
                }
            }
        }
    }
    Ok(query_rows(conn, &sql, &[])?
        .into_iter()
        .filter_map(|row| {
            let base = row.string("base").filter(|b| !b.is_empty())?;
            let ext = row.string("ext").unwrap_or("");
            let pick = row.double("pick").unwrap_or(0.0);
            let folder: String = [row.string("root"), row.string("sub")]
                .into_iter()
                .flatten()
                .collect();
            Some(CatalogEntry {
                filename: if ext.is_empty() {
                    base.to_string()
                } else {
                    format!("{base}.{ext}")
                },
                folder: (!folder.is_empty()).then_some(folder),
                rating: Some(row.double("rating").unwrap_or(0.0).round() as i64),
                flag: Some(if pick > 0.0 {
                    CaptureFlag::Pick
                } else if pick < 0.0 {
                    CaptureFlag::Reject
                } else {
                    CaptureFlag::None
                }),
                label: color_label_named(row.string("label")),
                keywords: row
                    .int("id")
                    .and_then(|id| keywords.get(&id).cloned())
                    .unwrap_or_default(),
            })
        })
        .collect())
}

/// Capture One (`.cocatalogdb` / `.cosessiondb`). Its schema is Core Data
/// style (Z-prefixed tables) and not documented, so the reader looks for it
/// rather than assuming: a table with an image file name, and a rating (and
/// colour tag) either on that table or on a variant table pointing at it.
/// Unverified against every Capture One version; treat as experimental.
pub fn capture_one(conn: &Connection) -> Result<Vec<CatalogEntry>> {
    let mut columns: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for table in table_names(conn)? {
        let cols = query_rows(conn, &format!("PRAGMA table_info(\"{table}\")"), &[])?
            .into_iter()
            .filter_map(|r| r.string("name").map(str::to_string))
            .collect();
        columns.insert(table, cols);
    }
    fn find(cols: &[String], patterns: &[&str]) -> Option<String> {
        patterns
            .iter()
            .find_map(|p| cols.iter().find(|c| c.to_uppercase().contains(p)).cloned())
    }
    let unrecognised = || CatalogError::UnrecognisedSchema("Capture One catalog".into());
    // The image table: has a file-name column (ZIMAGE preferred).
    let mut candidates: Vec<(String, String)> = columns
        .iter()
        .filter_map(|(t, cols)| {
            find(cols, &["FILENAME", "DISPLAYNAME", "IMAGENAME"]).map(|c| (t.clone(), c))
        })
        .collect();
    candidates.sort_by_key(|(t, _)| (t.to_uppercase() != "ZIMAGE", t.clone()));
    let (image_table, name_column) = candidates.into_iter().next().ok_or_else(unrecognised)?;

    let rating_patterns = ["RATING"];
    let color_patterns = ["COLORTAG", "COLORLABEL", "COLOURTAG"];
    let image_cols = columns.get(&image_table).cloned().unwrap_or_default();
    // Rating on the image table itself, or on a table referencing it.
    let source: Option<(String, String, Option<String>, Option<String>)> =
        match find(&image_cols, &rating_patterns) {
            Some(r) => Some((
                image_table.clone(),
                r,
                find(&image_cols, &color_patterns),
                None,
            )),
            None => {
                let fk_name = image_table.to_uppercase();
                columns
                    .iter()
                    .filter(|(t, _)| **t != image_table)
                    .find_map(|(table, cols)| {
                        let r = find(cols, &rating_patterns)?;
                        let fk = cols.iter().find(|c| c.to_uppercase() == fk_name)?.clone();
                        Some((table.clone(), r, find(cols, &color_patterns), Some(fk)))
                    })
            }
        };
    let (table, rating, color, join) = source.ok_or_else(unrecognised)?;
    let sql = match &join {
        Some(join) => format!(
            "SELECT i.\"{name_column}\" AS name, v.\"{rating}\" AS rating{} FROM \"{table}\" v JOIN \"{image_table}\" i ON i.Z_PK = v.\"{join}\"",
            color.as_ref().map(|c| format!(", v.\"{c}\" AS color")).unwrap_or_default()
        ),
        None => format!(
            "SELECT \"{name_column}\" AS name, \"{rating}\" AS rating{} FROM \"{image_table}\"",
            color.as_ref().map(|c| format!(", \"{c}\" AS color")).unwrap_or_default()
        ),
    };
    let mut seen: HashSet<String> = HashSet::new();
    Ok(query_rows(conn, &sql, &[])?
        .into_iter()
        .filter_map(|row| {
            let name = row.string("name").filter(|n| !n.is_empty())?;
            let rating = row.double("rating").unwrap_or(0.0) as i64;
            let entry = CatalogEntry {
                filename: util::last_path_component(name).to_string(),
                folder: None,
                rating: Some(rating.clamp(0, 5)),
                flag: (rating < 0).then_some(CaptureFlag::Reject),
                label: capture_one_color(row.int("color")),
                keywords: Vec::new(),
            };
            // Several variants of one image: the first (primary) wins.
            seen.insert(entry.filename.to_lowercase()).then_some(entry)
        })
        .collect())
}

/// Lightroom's label names; custom label sets leave ours alone (`None`).
pub fn color_label_named(name: Option<&str>) -> Option<ColorLabel> {
    match name
        .map(|n| n.trim_matches([' ', '\t']).to_lowercase())
        .as_deref()
    {
        Some("red") => Some(ColorLabel::Red),
        Some("yellow") => Some(ColorLabel::Yellow),
        Some("green") => Some(ColorLabel::Green),
        Some("blue") => Some(ColorLabel::Blue),
        Some("purple") => Some(ColorLabel::Purple),
        Some("") | None => Some(ColorLabel::None),
        _ => None,
    }
}

/// Capture One colour tags: 0 none, 1 red, 2 orange, 3 yellow, 4 green,
/// 5 blue, 6 pink, 7 purple. Orange and pink have no equivalent here.
pub fn capture_one_color(value: Option<i64>) -> Option<ColorLabel> {
    match value? {
        0 => Some(ColorLabel::None),
        1 => Some(ColorLabel::Red),
        3 => Some(ColorLabel::Yellow),
        4 => Some(ColorLabel::Green),
        5 => Some(ColorLabel::Blue),
        7 => Some(ColorLabel::Purple),
        _ => None,
    }
}

/// What a catalog would change on one capture here.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CatalogChange {
    pub capture_id: String,
    pub filename: String,
    pub rating: Option<i64>,
    pub flag: Option<CaptureFlag>,
    pub label: Option<ColorLabel>,
    pub new_keywords: Vec<String>,
}

impl CatalogChange {
    pub fn is_empty(&self) -> bool {
        self.rating.is_none()
            && self.flag.is_none()
            && self.label.is_none()
            && self.new_keywords.is_empty()
    }
}

/// The result of matching a catalog against the library.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CatalogMatch {
    pub changes: Vec<CatalogChange>,
    /// Catalog file names that matched no capture.
    pub unmatched: Vec<String>,
}

/// Match catalog entries to captures by file name: the camera's own name
/// first, then any name the frame was exported under. Only differences are
/// returned, in capture order.
pub fn match_catalog(
    entries: &[CatalogEntry],
    captures: &[CaptureItem],
    exported_names: &HashMap<String, String>,
    tags: impl Fn(&str) -> Vec<String>,
) -> CatalogMatch {
    let mut by_name: HashMap<String, &CaptureItem> = HashMap::new();
    for c in captures {
        by_name.entry(c.filename.to_lowercase()).or_insert(c);
    }
    let by_id: HashMap<&str, &CaptureItem> = captures.iter().map(|c| (c.id.as_str(), c)).collect();
    let mut out: HashMap<String, CatalogChange> = HashMap::new();
    let mut unmatched = Vec::new();
    for entry in entries {
        let key = entry.filename.to_lowercase();
        let capture = by_name.get(&key).copied().or_else(|| {
            exported_names
                .get(&key)
                .and_then(|id| by_id.get(id.as_str()).copied())
        });
        let Some(capture) = capture else {
            unmatched.push(entry.filename.clone());
            continue;
        };
        let change = out
            .entry(capture.id.clone())
            .or_insert_with(|| CatalogChange {
                capture_id: capture.id.clone(),
                filename: capture.filename.clone(),
                ..Default::default()
            });
        if let Some(r) = entry.rating.filter(|r| *r != capture.rating) {
            change.rating = Some(r);
        }
        if let Some(f) = entry.flag.filter(|f| *f != capture.flag) {
            change.flag = Some(f);
        }
        if let Some(l) = entry.label.filter(|l| *l != capture.color_label) {
            change.label = Some(l);
        }
        let existing: HashSet<String> = tags(&capture.id)
            .into_iter()
            .map(|t| t.to_lowercase())
            .collect();
        for k in &entry.keywords {
            if !existing.contains(&k.to_lowercase()) && !change.new_keywords.contains(k) {
                change.new_keywords.push(k.clone());
            }
        }
    }
    let changes = captures
        .iter()
        .filter_map(|c| out.remove(&c.id))
        .filter(|c| !c.is_empty())
        .collect();
    CatalogMatch { changes, unmatched }
}
