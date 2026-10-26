//! Collections and filters (`Library/Collection.swift`).

use std::collections::{BTreeSet, HashMap};

use chrono::{DateTime, Days, Local, TimeZone, Utc};
use rusqlite::types::Value as SqlValue;
use serde::{Deserialize, Deserializer, Serialize};

use crate::capture_item::{CaptureFlag, CaptureItem, ColorLabel, MediaKind};
use crate::swift_json::{self, Empty};

/// Manual (hand-picked) or smart (a saved query).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CollectionKind {
    Manual,
    Smart,
}

impl CollectionKind {
    pub fn raw(self) -> &'static str {
        match self {
            Self::Manual => "manual",
            Self::Smart => "smart",
        }
    }
}

/// A collection is either a hand-picked set of captures or a saved query.
/// Smart collections evaluate in SQL, so they stay instant at tens of
/// thousands of frames and update the moment a rating changes.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Collection {
    pub id: String,
    pub name: String,
    pub kind: CollectionKind,
    /// Smart only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rule: Option<CaptureFilter>,
    /// SF Symbol name (the UI maps it to its own icon set).
    pub symbol: String,
    /// Accent for the sidebar dot; `None` = neutral.
    pub tint: ColorLabel,
    #[serde(rename = "isPinned")]
    pub is_pinned: bool,
    #[serde(rename = "sortOrder")]
    pub sort_order: i64,
    #[serde(rename = "createdAt", with = "swift_json::date")]
    pub created_at: DateTime<Utc>,
    #[serde(rename = "updatedAt", with = "swift_json::date")]
    pub updated_at: DateTime<Utc>,
    /// Built-ins (All, Picks, Today…) cannot be deleted or renamed.
    #[serde(rename = "isBuiltIn")]
    pub is_built_in: bool,
}

impl Collection {
    pub fn new(name: impl Into<String>, kind: CollectionKind) -> Self {
        let now = Utc::now();
        Self {
            id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            name: name.into(),
            kind,
            rule: None,
            symbol: "rectangle.stack".into(),
            tint: ColorLabel::None,
            is_pinned: false,
            sort_order: 0,
            created_at: now,
            updated_at: now,
            is_built_in: false,
        }
    }

    pub fn smart(
        name: &str,
        rule: CaptureFilter,
        symbol: &str,
        id: Option<&str>,
        built_in: bool,
    ) -> Self {
        let mut c = Self::new(name, CollectionKind::Smart);
        if let Some(id) = id {
            c.id = id.to_string();
        }
        c.rule = Some(rule);
        c.symbol = symbol.to_string();
        c.is_built_in = built_in;
        c
    }

    /// The library's fixed shelves. Seeded once; their rules can't change.
    pub fn built_ins() -> Vec<Collection> {
        vec![
            Self::smart(
                "All photos",
                CaptureFilter::default(),
                "photo.on.rectangle",
                Some("builtin.all"),
                true,
            ),
            Self::smart(
                "Picks",
                CaptureFilter {
                    flags: Some([CaptureFlag::Pick].into()),
                    ..Default::default()
                },
                "flag.fill",
                Some("builtin.picks"),
                true,
            ),
            Self::smart(
                "Five stars",
                CaptureFilter {
                    min_rating: Some(5),
                    ..Default::default()
                },
                "star.fill",
                Some("builtin.5"),
                true,
            ),
            Self::smart(
                "Unrated",
                CaptureFilter {
                    max_rating: Some(0),
                    flags: Some([CaptureFlag::None].into()),
                    ..Default::default()
                },
                "circle.dashed",
                Some("builtin.unrated"),
                true,
            ),
            Self::smart(
                "Today",
                CaptureFilter {
                    date_range: Some(DateRange::Today),
                    ..Default::default()
                },
                "sun.max",
                Some("builtin.today"),
                true,
            ),
            Self::smart(
                "Rejects",
                CaptureFilter {
                    flags: Some([CaptureFlag::Reject].into()),
                    ..Default::default()
                },
                "xmark.bin",
                Some("builtin.rejects"),
                true,
            ),
        ]
    }
}

/// A capture-time window.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(into = "DateRangeRepr", from = "DateRangeRepr")]
pub enum DateRange {
    Today,
    Last7Days,
    Last30Days,
    Between(DateTime<Utc>, DateTime<Utc>),
}

#[derive(Serialize, Deserialize)]
enum DateRangeRepr {
    #[serde(rename = "today")]
    Today(Empty),
    #[serde(rename = "last7Days")]
    Last7Days(Empty),
    #[serde(rename = "last30Days")]
    Last30Days(Empty),
    #[serde(rename = "between")]
    Between {
        #[serde(rename = "_0", with = "swift_json::date")]
        from: DateTime<Utc>,
        #[serde(rename = "_1", with = "swift_json::date")]
        to: DateTime<Utc>,
    },
}

impl From<DateRange> for DateRangeRepr {
    fn from(d: DateRange) -> Self {
        match d {
            DateRange::Today => Self::Today(Empty {}),
            DateRange::Last7Days => Self::Last7Days(Empty {}),
            DateRange::Last30Days => Self::Last30Days(Empty {}),
            DateRange::Between(from, to) => Self::Between { from, to },
        }
    }
}

impl From<DateRangeRepr> for DateRange {
    fn from(d: DateRangeRepr) -> Self {
        match d {
            DateRangeRepr::Today(_) => Self::Today,
            DateRangeRepr::Last7Days(_) => Self::Last7Days,
            DateRangeRepr::Last30Days(_) => Self::Last30Days,
            DateRangeRepr::Between { from, to } => Self::Between(from, to),
        }
    }
}

/// Export destinations as the library records them. `Never` rather than
/// `None` so `exported_to: Some(Never)` can't be mistaken for "no filter".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ExportDestinationKey {
    Photos,
    Files,
    Ftp,
    Any,
    Never,
}

impl ExportDestinationKey {
    pub const ALL: [ExportDestinationKey; 5] =
        [Self::Photos, Self::Files, Self::Ftp, Self::Any, Self::Never];

    pub fn raw(self) -> &'static str {
        match self {
            Self::Photos => "photos",
            Self::Files => "files",
            Self::Ftp => "ftp",
            Self::Any => "any",
            Self::Never => "never",
        }
    }
}

/// Filters saved when a cloud destination existed read as "any export".
impl<'de> Deserialize<'de> for ExportDestinationKey {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(d)?;
        Ok(Self::ALL
            .into_iter()
            .find(|k| k.raw() == raw)
            .unwrap_or(Self::Any))
    }
}

fn default_true() -> bool {
    true
}

/// A query over the library. Every field is optional; empty means "any".
/// Translates to one SQL WHERE clause ([`CaptureFilter::sql`]), so it is
/// also the filter bar's model and the smart-collection rule.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct CaptureFilter {
    #[serde(rename = "minRating", default, skip_serializing_if = "Option::is_none")]
    pub min_rating: Option<i64>,
    #[serde(rename = "maxRating", default, skip_serializing_if = "Option::is_none")]
    pub max_rating: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub flags: Option<BTreeSet<CaptureFlag>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub colors: Option<BTreeSet<ColorLabel>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kinds: Option<BTreeSet<MediaKind>>,
    #[serde(
        rename = "sessionIDs",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub session_ids: Option<BTreeSet<String>>,
    #[serde(rename = "cameraIDs", default, skip_serializing_if = "Option::is_none")]
    pub camera_ids: Option<BTreeSet<String>>,
    /// Must carry every tag.
    #[serde(rename = "tagsAll", default, skip_serializing_if = "Option::is_none")]
    pub tags_all: Option<BTreeSet<String>>,
    /// Must carry at least one.
    #[serde(rename = "tagsAny", default, skip_serializing_if = "Option::is_none")]
    pub tags_any: Option<BTreeSet<String>>,
    #[serde(rename = "dateRange", default, skip_serializing_if = "Option::is_none")]
    pub date_range: Option<DateRange>,
    /// Filename / session name / tag contains.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(rename = "readyOnly", default = "default_true")]
    pub ready_only: bool,
    #[serde(rename = "hasLook", default, skip_serializing_if = "Option::is_none")]
    pub has_look: Option<bool>,
    #[serde(
        rename = "exportedTo",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub exported_to: Option<ExportDestinationKey>,
}

impl Default for CaptureFilter {
    fn default() -> Self {
        Self {
            min_rating: None,
            max_rating: None,
            flags: None,
            colors: None,
            kinds: None,
            session_ids: None,
            camera_ids: None,
            tags_all: None,
            tags_any: None,
            date_range: None,
            text: None,
            ready_only: true,
            has_look: None,
            exported_to: None,
        }
    }
}

fn capitalized(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + &c.as_str().to_lowercase(),
        None => String::new(),
    }
}

fn in_list(col: &str, n: usize) -> String {
    format!("{col} IN ({})", vec!["?"; n].join(","))
}

fn text_params<I: IntoIterator<Item = &'static str>>(raws: I) -> Vec<SqlValue> {
    let mut v: Vec<&str> = raws.into_iter().collect();
    v.sort_unstable();
    v.into_iter()
        .map(|s| SqlValue::Text(s.to_string()))
        .collect()
}

impl CaptureFilter {
    /// Ready and unready frames alike (manual collections list everything).
    pub fn any_state() -> Self {
        Self {
            ready_only: false,
            ..Default::default()
        }
    }

    pub fn is_empty(&self) -> bool {
        self.min_rating.is_none()
            && self.max_rating.is_none()
            && self.flags.is_none()
            && self.colors.is_none()
            && self.kinds.is_none()
            && self.session_ids.is_none()
            && self.camera_ids.is_none()
            && self.tags_all.is_none()
            && self.tags_any.is_none()
            && self.date_range.is_none()
            && self.text.as_deref().unwrap_or("").is_empty()
            && self.has_look.is_none()
            && self.exported_to.is_none()
    }

    /// Human summary for chips: "4★+ · Pick · blue, red · #hero".
    pub fn summary(&self) -> String {
        let mut parts: Vec<String> = Vec::new();
        if let Some(r) = self.min_rating.filter(|r| *r > 0) {
            parts.push(format!("{r}★+"));
        }
        if self.max_rating == Some(0) {
            parts.push("unrated".into());
        }
        if let Some(f) = self.flags.as_ref().filter(|f| !f.is_empty()) {
            let mut raws: Vec<&str> = f.iter().map(|x| x.raw()).collect();
            raws.sort_unstable();
            parts.push(
                raws.iter()
                    .map(|r| capitalized(r))
                    .collect::<Vec<_>>()
                    .join("/"),
            );
        }
        if let Some(c) = self.colors.as_ref().filter(|c| !c.is_empty()) {
            let mut raws: Vec<&str> = c.iter().map(|x| x.raw()).collect();
            raws.sort_unstable();
            parts.push(raws.join(", "));
        }
        if let Some(k) = self.kinds.as_ref().filter(|k| !k.is_empty()) {
            let mut raws: Vec<String> = k.iter().map(|x| x.raw().to_uppercase()).collect();
            raws.sort_unstable();
            parts.push(raws.join("/"));
        }
        if let Some(t) = self.tags_all.as_ref().filter(|t| !t.is_empty()) {
            parts.push(
                t.iter()
                    .map(|t| format!("#{t}"))
                    .collect::<Vec<_>>()
                    .join(" "),
            );
        }
        if let Some(t) = self.tags_any.as_ref().filter(|t| !t.is_empty()) {
            parts.push(format!(
                "any of {}",
                t.iter()
                    .map(|t| format!("#{t}"))
                    .collect::<Vec<_>>()
                    .join(" ")
            ));
        }
        match self.date_range {
            Some(DateRange::Today) => parts.push("today".into()),
            Some(DateRange::Last7Days) => parts.push("last 7 days".into()),
            Some(DateRange::Last30Days) => parts.push("last 30 days".into()),
            Some(DateRange::Between(..)) => parts.push("date range".into()),
            None => {}
        }
        if let Some(s) = self.session_ids.as_ref().filter(|s| !s.is_empty()) {
            parts.push(if s.len() == 1 {
                "1 session".into()
            } else {
                format!("{} sessions", s.len())
            });
        }
        if let Some(c) = self.camera_ids.as_ref().filter(|c| !c.is_empty()) {
            parts.push(if c.len() == 1 {
                "1 camera".into()
            } else {
                format!("{} cameras", c.len())
            });
        }
        if let Some(t) = self.text.as_ref().filter(|t| !t.is_empty()) {
            parts.push(format!("\u{201C}{t}\u{201D}"));
        }
        if let Some(e) = self.exported_to {
            parts.push(match e {
                ExportDestinationKey::Never => "not exported".into(),
                ExportDestinationKey::Any => "exported".into(),
                other => format!("exported to {}", other.raw()),
            });
        }
        if parts.is_empty() {
            "Everything".into()
        } else {
            parts.join(" · ")
        }
    }

    /// WHERE clause over the `captures` table (aliased `c`) with bound values.
    /// Tags and exports use EXISTS sub-selects so the main query stays flat.
    pub fn sql(&self, now: DateTime<Utc>) -> (String, Vec<SqlValue>) {
        let mut clauses: Vec<String> = Vec::new();
        let mut params: Vec<SqlValue> = Vec::new();
        if self.ready_only {
            clauses.push("c.state = 'ready'".into());
        }
        if let Some(r) = self.min_rating {
            clauses.push("c.rating >= ?".into());
            params.push(SqlValue::Integer(r));
        }
        if let Some(r) = self.max_rating {
            clauses.push("c.rating <= ?".into());
            params.push(SqlValue::Integer(r));
        }
        if let Some(f) = self.flags.as_ref().filter(|f| !f.is_empty()) {
            clauses.push(in_list("c.flag", f.len()));
            params.extend(text_params(f.iter().map(|x| x.raw())));
        }
        if let Some(c) = self.colors.as_ref().filter(|c| !c.is_empty()) {
            clauses.push(in_list("c.color", c.len()));
            params.extend(text_params(c.iter().map(|x| x.raw())));
        }
        if let Some(k) = self.kinds.as_ref().filter(|k| !k.is_empty()) {
            clauses.push(in_list("c.kind", k.len()));
            params.extend(text_params(k.iter().map(|x| x.raw())));
        }
        if let Some(s) = self.session_ids.as_ref().filter(|s| !s.is_empty()) {
            clauses.push(in_list("c.session_id", s.len()));
            params.extend(s.iter().map(|x| SqlValue::Text(x.clone())));
        }
        if let Some(cams) = self.camera_ids.as_ref().filter(|s| !s.is_empty()) {
            clauses.push(in_list("c.camera_id", cams.len()));
            params.extend(cams.iter().map(|x| SqlValue::Text(x.clone())));
        }
        if let Some(t) = self.tags_all.as_ref().filter(|t| !t.is_empty()) {
            for tag in t {
                clauses.push(
                    "EXISTS (SELECT 1 FROM capture_tags t WHERE t.capture_id = c.id AND t.tag = ?)"
                        .into(),
                );
                params.push(SqlValue::Text(tag.clone()));
            }
        }
        if let Some(t) = self.tags_any.as_ref().filter(|t| !t.is_empty()) {
            clauses.push(format!(
                "EXISTS (SELECT 1 FROM capture_tags t WHERE t.capture_id = c.id AND {})",
                in_list("t.tag", t.len())
            ));
            params.extend(t.iter().map(|x| SqlValue::Text(x.clone())));
        }
        if let Some(d) = self.date_range {
            let local_now = now.with_timezone(&Local);
            let (from, to): (DateTime<Utc>, Option<DateTime<Utc>>) = match d {
                DateRange::Today => {
                    let midnight = local_now
                        .date_naive()
                        .and_hms_opt(0, 0, 0)
                        .unwrap_or_default();
                    let start = Local
                        .from_local_datetime(&midnight)
                        .earliest()
                        .map(|d| d.with_timezone(&Utc))
                        .unwrap_or(now);
                    (start, None)
                }
                DateRange::Last7Days => (
                    local_now
                        .checked_sub_days(Days::new(7))
                        .map(|d| d.with_timezone(&Utc))
                        .unwrap_or(now),
                    None,
                ),
                DateRange::Last30Days => (
                    local_now
                        .checked_sub_days(Days::new(30))
                        .map(|d| d.with_timezone(&Utc))
                        .unwrap_or(now),
                    None,
                ),
                DateRange::Between(a, b) => (a, Some(b)),
            };
            clauses.push("c.received_at >= ?".into());
            params.push(SqlValue::Real(swift_json::unix_seconds(&from)));
            if let Some(to) = to {
                clauses.push("c.received_at <= ?".into());
                params.push(SqlValue::Real(swift_json::unix_seconds(&to)));
            }
        }
        if let Some(t) = self
            .text
            .as_deref()
            .map(|t| t.trim_matches([' ', '\t']))
            .filter(|t| !t.is_empty())
        {
            clauses.push("(c.filename LIKE ? ESCAPE '\\' OR EXISTS (SELECT 1 FROM sessions s WHERE s.id = c.session_id AND s.name LIKE ? ESCAPE '\\') OR EXISTS (SELECT 1 FROM capture_tags t WHERE t.capture_id = c.id AND t.tag LIKE ? ESCAPE '\\'))".into());
            let like = format!(
                "%{}%",
                t.replace('\\', "\\\\")
                    .replace('%', "\\%")
                    .replace('_', "\\_")
            );
            params.extend(std::iter::repeat_n(SqlValue::Text(like), 3));
        }
        if let Some(h) = self.has_look {
            clauses.push(
                if h {
                    "c.look_id IS NOT NULL"
                } else {
                    "c.look_id IS NULL"
                }
                .into(),
            );
        }
        if let Some(e) = self.exported_to {
            match e {
                ExportDestinationKey::Never => clauses.push(
                    "NOT EXISTS (SELECT 1 FROM capture_exports x WHERE x.capture_id = c.id)".into(),
                ),
                ExportDestinationKey::Any => clauses.push(
                    "EXISTS (SELECT 1 FROM capture_exports x WHERE x.capture_id = c.id)".into(),
                ),
                other => {
                    clauses.push(
                        "EXISTS (SELECT 1 FROM capture_exports x WHERE x.capture_id = c.id AND x.destination = ?)"
                            .into(),
                    );
                    params.push(SqlValue::Text(other.raw().into()));
                }
            }
        }
        let w = if clauses.is_empty() {
            "1=1".to_string()
        } else {
            clauses.join(" AND ")
        };
        (w, params)
    }

    /// Intersection of two filters (both must hold).
    pub fn merged(&self, other: &CaptureFilter) -> CaptureFilter {
        fn inter<T: Ord + Clone>(
            a: &Option<BTreeSet<T>>,
            b: &Option<BTreeSet<T>>,
        ) -> Option<BTreeSet<T>> {
            match (a, b) {
                (Some(a), Some(b)) => Some(a.intersection(b).cloned().collect()),
                (Some(a), None) => Some(a.clone()),
                (None, b) => b.clone(),
            }
        }
        let mut out = self.clone();
        out.min_rating = [self.min_rating, other.min_rating]
            .into_iter()
            .flatten()
            .max();
        out.max_rating = [self.max_rating, other.max_rating]
            .into_iter()
            .flatten()
            .min();
        out.flags = inter(&self.flags, &other.flags);
        out.colors = inter(&self.colors, &other.colors);
        out.kinds = inter(&self.kinds, &other.kinds);
        out.session_ids = inter(&self.session_ids, &other.session_ids);
        out.camera_ids = inter(&self.camera_ids, &other.camera_ids);
        let all: BTreeSet<String> = self
            .tags_all
            .iter()
            .chain(other.tags_all.iter())
            .flatten()
            .cloned()
            .collect();
        out.tags_all = if all.is_empty() { None } else { Some(all) };
        out.tags_any = inter(&self.tags_any, &other.tags_any);
        out.date_range = other.date_range.or(self.date_range);
        let text: Vec<&str> = [self.text.as_deref(), other.text.as_deref()]
            .into_iter()
            .flatten()
            .filter(|t| !t.is_empty())
            .collect();
        out.text = if text.is_empty() {
            None
        } else {
            Some(text.join(" "))
        };
        out.ready_only = self.ready_only || other.ready_only;
        out.has_look = other.has_look.or(self.has_look);
        out.exported_to = other.exported_to.or(self.exported_to);
        out
    }
}

/// Sort for grids and filmstrips. Persisted per view in workspace memory.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum CaptureSort {
    CaptureTimeAscending,
    #[default]
    CaptureTimeDescending,
    RatingDescending,
    Filename,
    SessionThenTime,
}

impl CaptureSort {
    pub const ALL: [CaptureSort; 5] = [
        Self::CaptureTimeAscending,
        Self::CaptureTimeDescending,
        Self::RatingDescending,
        Self::Filename,
        Self::SessionThenTime,
    ];

    pub fn display_name(self) -> &'static str {
        match self {
            Self::CaptureTimeAscending => "Oldest first",
            Self::CaptureTimeDescending => "Newest first",
            Self::RatingDescending => "Rating",
            Self::Filename => "Filename",
            Self::SessionThenTime => "Session",
        }
    }

    pub(crate) fn order_by(self) -> &'static str {
        match self {
            Self::CaptureTimeAscending => "c.received_at ASC, c.sequence ASC",
            Self::CaptureTimeDescending => "c.received_at DESC, c.sequence DESC",
            Self::RatingDescending => "c.rating DESC, c.received_at DESC",
            Self::Filename => "c.filename COLLATE NOCASE ASC",
            Self::SessionThenTime => "c.session_id ASC, c.sequence ASC",
        }
    }
}

/// RAW+JPEG stacking: the grid shows one tile per pair with the JPEG on top.
#[derive(Debug, Clone, PartialEq)]
pub struct CaptureStack {
    pub key: String,
    pub items: Vec<CaptureItem>,
}

impl CaptureStack {
    pub fn id(&self) -> &str {
        &self.key
    }

    pub fn top(&self) -> &CaptureItem {
        self.items
            .iter()
            .find(|i| i.kind != MediaKind::Raw)
            .unwrap_or(&self.items[0])
    }

    pub fn is_pair(&self) -> bool {
        self.items.len() > 1
    }

    pub fn stack(items: &[CaptureItem]) -> Vec<CaptureStack> {
        let mut order: Vec<String> = Vec::new();
        let mut groups: HashMap<String, Vec<CaptureItem>> = HashMap::new();
        for i in items {
            let k = format!("{}/{}", i.session_id, i.pair_key);
            let g = groups.entry(k.clone()).or_default();
            if g.is_empty() {
                order.push(k);
            }
            g.push(i.clone());
        }
        order
            .into_iter()
            .map(|k| {
                let items = groups.remove(&k).unwrap_or_default();
                CaptureStack { key: k, items }
            })
            .collect()
    }
}
