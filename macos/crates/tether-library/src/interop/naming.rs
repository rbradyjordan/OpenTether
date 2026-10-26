//! Naming templates, folder layouts and session manifests
//! (`Interop/NamingAndLayout.swift`).

use std::collections::HashMap;

use chrono::{DateTime, Local, Utc};
use serde::{Deserialize, Serialize};

use crate::capture_item::{CaptureFlag, CaptureItem, ColorLabel, MediaKind, ShootSession};
use crate::{swift_json, util};

/// Filename / folder / caption templates with the tokens pros expect from
/// Capture One and Photo Mechanic style renamers.
///
/// Tokens: `{orig}` original base name · `{ext}` extension · `{session}` ·
/// `{date}` yyyy-MM-dd · `{time}` HHmmss · `{year}` `{month}` `{day}` ·
/// `{seq}` or `{seq:4}` zero-padded sequence · `{camera}` · `{rating}` ·
/// `{label}` · `{pick}` ("pick"/"reject"/"") · `{kind}` (jpeg/raw) ·
/// `{tag}` first tag · `{client}` workflow tag. Unknown tokens are kept.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct NamingTemplate {
    pub pattern: String,
}

/// What a template can draw on besides the capture itself.
#[derive(Debug, Clone, Default)]
pub struct NamingContext<'a> {
    pub session_name: Option<&'a str>,
    pub index: i64,
    pub camera: Option<&'a str>,
    pub tags: &'a [String],
    pub client: Option<&'a str>,
    /// Date for the date tokens; the capture time when `None`.
    pub now: Option<DateTime<Utc>>,
}

impl NamingTemplate {
    pub fn new(pattern: impl Into<String>) -> Self {
        Self {
            pattern: pattern.into(),
        }
    }

    pub fn original() -> Self {
        Self::new("{orig}")
    }

    pub fn session_sequence() -> Self {
        Self::new("{session}_{seq:4}")
    }

    pub fn dated() -> Self {
        Self::new("{date}_{session}_{seq:4}")
    }

    pub fn presets() -> Vec<Self> {
        vec![
            Self::original(),
            Self::session_sequence(),
            Self::dated(),
            Self::new("{client}_{date}_{seq:3}"),
        ]
    }

    /// Shorthand for the common case (session name and index only).
    pub fn render_simple(
        &self,
        capture: &CaptureItem,
        session_name: Option<&str>,
        index: i64,
    ) -> String {
        self.render(
            capture,
            &NamingContext {
                session_name,
                index,
                ..Default::default()
            },
        )
    }

    pub fn render(&self, capture: &CaptureItem, ctx: &NamingContext<'_>) -> String {
        let d = ctx.now.unwrap_or(capture.captured_at).with_timezone(&Local);
        let fmt = |f: &str| d.format(f).to_string();
        let mut out = expand_seq(&self.pattern, ctx.index);
        let base = util::delete_path_extension(&capture.filename).to_string();
        let pairs: [(&str, String); 15] = [
            ("{orig}", base.clone()),
            (
                "{ext}",
                util::path_extension(&capture.filename).to_lowercase(),
            ),
            (
                "{session}",
                Self::safe(ctx.session_name.unwrap_or("Session"), false),
            ),
            ("{date}", fmt("%Y-%m-%d")),
            ("{time}", fmt("%H%M%S")),
            ("{year}", fmt("%Y")),
            ("{month}", fmt("%m")),
            ("{day}", fmt("%d")),
            ("{camera}", Self::safe(ctx.camera.unwrap_or(""), false)),
            (
                "{rating}",
                if capture.rating > 0 {
                    capture.rating.to_string()
                } else {
                    "0".into()
                },
            ),
            (
                "{label}",
                if capture.color_label == ColorLabel::None {
                    String::new()
                } else {
                    capture.color_label.raw().into()
                },
            ),
            (
                "{pick}",
                match capture.flag {
                    CaptureFlag::Pick => "pick".into(),
                    CaptureFlag::Reject => "reject".into(),
                    CaptureFlag::None => String::new(),
                },
            ),
            (
                "{kind}",
                if capture.kind == MediaKind::Raw {
                    "raw".into()
                } else {
                    "jpeg".into()
                },
            ),
            (
                "{tag}",
                Self::safe(ctx.tags.first().map(String::as_str).unwrap_or(""), false),
            ),
            ("{client}", Self::safe(ctx.client.unwrap_or(""), false)),
        ];
        for (k, v) in pairs {
            out = out.replace(k, &v);
        }
        let safe = Self::safe(&out, true);
        if safe.is_empty() {
            base
        } else {
            safe
        }
    }

    /// Filesystem-safe: strips path separators and control characters,
    /// collapses doubles, trims dots so Finder/Windows both accept it.
    /// `keep_separators` keeps `/` (for templates that make folders).
    pub fn safe(s: &str, keep_separators: bool) -> String {
        let bad = |c: char| {
            matches!(c, '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '\0')
                || (!keep_separators && c == '/')
                || c.is_control()
                || matches!(c, '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2060}'..='\u{2064}' | '\u{FEFF}' | '\u{AD}')
        };
        let mut out: String = s.chars().map(|c| if bad(c) { '_' } else { c }).collect();
        while out.contains("__") {
            out = out.replace("__", "_");
        }
        out.trim_matches([' ', '.', '_']).to_string()
    }
}

/// `{seq}` / `{seq:N}` → zero-padded `index` (width 4 by default).
fn expand_seq(pattern: &str, index: i64) -> String {
    let mut out = String::with_capacity(pattern.len());
    let mut rest = pattern;
    while let Some(pos) = rest.find("{seq") {
        out.push_str(&rest[..pos]);
        let after = &rest[pos + 4..];
        let mut consumed = None;
        if let Some(stripped) = after.strip_prefix('}') {
            consumed = Some((4usize, stripped));
        } else if let Some(digits) = after.strip_prefix(':') {
            let n = digits.chars().take_while(char::is_ascii_digit).count();
            if n > 0 && digits[n..].starts_with('}') {
                let width = digits[..n].parse::<usize>().unwrap_or(4);
                consumed = Some((width, &digits[n + 1..]));
            }
        }
        match consumed {
            Some((width, tail)) => {
                out.push_str(&format!("{index:0width$}"));
                rest = tail;
            }
            None => {
                out.push_str("{seq");
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// How an export lays out folders. `CaptureOne` is the Capture One session
/// tree (Capture / Selects / Output / Trash) so a shoot drops straight into
/// a C1 session; `Dated` suits Lightroom's import by date.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum FolderLayout {
    #[default]
    Flat,
    Dated,
    BySession,
    CaptureOne,
    ByRating,
    /// Straight into an existing Capture One session folder (no session
    /// sub-folder): Capture / Selects / Trash / Output.
    CaptureOneSessionRoot,
}

impl FolderLayout {
    pub const ALL: [FolderLayout; 6] = [
        Self::Flat,
        Self::Dated,
        Self::BySession,
        Self::CaptureOne,
        Self::ByRating,
        Self::CaptureOneSessionRoot,
    ];

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Flat => "Flat",
            Self::Dated => "By date (yyyy/yyyy-MM-dd)",
            Self::BySession => "By session",
            Self::CaptureOne => "Capture One session",
            Self::CaptureOneSessionRoot => "Into a Capture One session",
            Self::ByRating => "By rating",
        }
    }

    fn capture_one_bucket(capture: &CaptureItem) -> &'static str {
        match capture.flag {
            CaptureFlag::Pick => "Selects",
            CaptureFlag::Reject => "Trash",
            CaptureFlag::None => "Capture",
        }
    }

    /// Relative directory for one capture. Capture One: picks → Selects,
    /// rejects → Trash, everything else → Capture; sidecars ride along.
    pub fn directory(
        self,
        capture: &CaptureItem,
        session_name: Option<&str>,
        date: Option<DateTime<Utc>>,
    ) -> String {
        let d = date.unwrap_or(capture.captured_at).with_timezone(&Local);
        let session = NamingTemplate::safe(session_name.unwrap_or("Session"), false);
        match self {
            Self::Flat => String::new(),
            Self::Dated => format!("{}/{}", d.format("%Y"), d.format("%Y-%m-%d")),
            Self::BySession => session,
            Self::CaptureOne => format!("{session}/{}", Self::capture_one_bucket(capture)),
            Self::ByRating => {
                if capture.rating > 0 {
                    format!(
                        "{} star{}",
                        capture.rating,
                        if capture.rating == 1 { "" } else { "s" }
                    )
                } else {
                    "Unrated".into()
                }
            }
            Self::CaptureOneSessionRoot => Self::capture_one_bucket(capture).into(),
        }
    }

    /// Where the manifest goes: Capture One's Output folder, else the root.
    pub fn manifest_directory(self, session_name: Option<&str>) -> String {
        match self {
            Self::CaptureOne => format!(
                "{}/Output",
                NamingTemplate::safe(session_name.unwrap_or("Session"), false)
            ),
            Self::CaptureOneSessionRoot => "Output".into(),
            _ => String::new(),
        }
    }

    /// Folders every layout creates up front so the tree is recognisable
    /// even when a bucket is empty (Capture One expects all four).
    pub fn scaffold(self, session_name: Option<&str>) -> Vec<String> {
        let session = NamingTemplate::safe(session_name.unwrap_or("Session"), false);
        let four = ["Capture", "Selects", "Output", "Trash"];
        match self {
            Self::CaptureOne => four.iter().map(|f| format!("{session}/{f}")).collect(),
            Self::CaptureOneSessionRoot => four.iter().map(|f| f.to_string()).collect(),
            Self::BySession => vec![session],
            _ => Vec::new(),
        }
    }
}

/// One frame in a manifest.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ManifestRow {
    pub filename: String,
    #[serde(
        rename = "exportedAs",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub exported_as: Option<String>,
    pub kind: String,
    pub rating: i64,
    pub flag: String,
    pub label: String,
    pub tags: Vec<String>,
    pub collections: Vec<String>,
    #[serde(rename = "capturedAt", with = "swift_json::iso_date")]
    pub captured_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub camera: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exposure: Option<String>,
    pub width: i64,
    pub height: i64,
    pub bytes: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
}

/// A machine-readable record of a session or export for other tools and
/// for the business platform: JSON for software, CSV for Photo Mechanic,
/// Excel and client sign-off sheets.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionManifest {
    pub generator: String,
    pub version: i64,
    pub session: String,
    #[serde(rename = "sessionID")]
    pub session_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub camera: Option<String>,
    #[serde(rename = "createdAt", with = "swift_json::iso_date")]
    pub created_at: DateTime<Utc>,
    #[serde(rename = "exportedAt", with = "swift_json::iso_date")]
    pub exported_at: DateTime<Utc>,
    #[serde(
        rename = "workflowTag",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub workflow_tag: Option<String>,
    pub rows: Vec<ManifestRow>,
}

impl SessionManifest {
    pub fn new(
        session: &ShootSession,
        captures: &[CaptureItem],
        tags: &HashMap<String, Vec<String>>,
        collections: &HashMap<String, Vec<String>>,
        exported_names: &HashMap<String, String>,
    ) -> Self {
        let camera = session
            .camera
            .as_ref()
            .map(|c| c.display_name().to_string());
        Self {
            generator: "Tether".into(),
            version: 1,
            session: session.name.clone(),
            session_id: session.id.clone(),
            camera: camera.clone(),
            created_at: session.created_at,
            exported_at: Utc::now(),
            workflow_tag: session.workflow_tag.clone(),
            rows: captures
                .iter()
                .map(|c| ManifestRow {
                    filename: c.filename.clone(),
                    exported_as: exported_names.get(&c.id).cloned(),
                    kind: c.kind.raw().into(),
                    rating: c.rating,
                    flag: c.flag.raw().into(),
                    label: c.color_label.raw().into(),
                    tags: tags.get(&c.id).cloned().unwrap_or_default(),
                    collections: collections.get(&c.id).cloned().unwrap_or_default(),
                    captured_at: c.captured_at,
                    camera: camera.clone(),
                    exposure: c.exposure.as_ref().map(|e| e.line()),
                    width: c.width,
                    height: c.height,
                    bytes: c.bytes,
                    sha256: None,
                })
                .collect(),
        }
    }

    /// Pretty-printed JSON with sorted keys and ISO 8601 dates.
    pub fn json(&self) -> serde_json::Result<Vec<u8>> {
        // Round-trip through `Value` (a sorted map) to sort the keys.
        let value = serde_json::to_value(self)?;
        serde_json::to_vec_pretty(&value)
    }

    /// RFC 4180 CSV with a header row; lists are `;`-joined.
    pub fn csv(&self) -> String {
        let q = |s: &str| format!("\"{}\"", s.replace('"', "\"\""));
        let mut out = String::from(
            "filename,exported_as,kind,rating,flag,label,tags,collections,captured_at,camera,exposure,width,height,bytes\r\n",
        );
        for r in &self.rows {
            let cells = [
                q(&r.filename),
                q(r.exported_as.as_deref().unwrap_or("")),
                r.kind.clone(),
                r.rating.to_string(),
                r.flag.clone(),
                r.label.clone(),
                q(&r.tags.join(";")),
                q(&r.collections.join(";")),
                swift_json::iso_date::format(&r.captured_at),
                q(r.camera.as_deref().unwrap_or("")),
                q(r.exposure.as_deref().unwrap_or("")),
                r.width.to_string(),
                r.height.to_string(),
                r.bytes.to_string(),
            ];
            out += &cells.join(",");
            out += "\r\n";
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seq_tokens() {
        assert_eq!(expand_seq("{seq}", 12), "0012");
        assert_eq!(expand_seq("a{seq:3}b{seq:x}", 7), "a007b{seq:x}");
    }
}
