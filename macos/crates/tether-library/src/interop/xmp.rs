//! XMP sidecars and embedded packets (`Interop/XMP.swift`).
//!
//! The metadata other pro tools read. Written as an XMP sidecar next to RAW
//! files and embedded as an APP1 packet in exported JPEGs, so Lightroom,
//! Capture One, Bridge and Photo Mechanic see the same rating, label,
//! keywords and copyright Tether shows.
//!
//! Mapping used (the de-facto conventions these apps share):
//! - rating        → `xmp:Rating` 0–5; reject → `xmp:Rating = -1` (Lightroom/Bridge)
//! - colour label  → `xmp:Label` with Lightroom's names (Red, Yellow, Green, Blue, Purple)
//!   and `photomechanic:ColorClass` 1–8 for Photo Mechanic
//! - pick          → `photomechanic:Tagged = True` plus keyword `tether:pick`
//!   (Lightroom does not store its flag in XMP)
//! - tags          → `dc:subject` bag and `lr:hierarchicalSubject`
//! - creator/copyright/caption/headline → `dc:creator`, `dc:rights`,
//!   `dc:description`, `photoshop:Headline`, `xmpRights:Marked`

use std::collections::{BTreeSet, HashMap};

use chrono::{DateTime, Datelike, Local, Utc};
use quick_xml::events::Event;
use serde::{Deserialize, Serialize};

use crate::capture_item::{CaptureFlag, CaptureItem, ColorLabel};
use crate::interop::exif::parse_ptp_datetime;
use crate::interop::naming::NamingTemplate;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum XmpError {
    #[error("malformed XMP: {0}")]
    Malformed(String),
    #[error("not a JPEG")]
    NotJpeg,
    #[error("no XMP packet in this file")]
    NoPacket,
}

/// The fields Tether reads and writes; anything else in a packet we parse
/// is ignored, and `extra_descriptions` are written back verbatim.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct XmpPacket {
    /// -1 reject, 0 none, 1–5.
    pub rating: Option<i64>,
    pub label: Option<ColorLabel>,
    pub pick: bool,
    pub keywords: Vec<String>,
    /// `"Clients|Acme|AW26"`.
    pub hierarchical_keywords: Vec<String>,
    pub title: Option<String>,
    pub caption: Option<String>,
    pub headline: Option<String>,
    pub creator: Option<String>,
    pub copyright: Option<String>,
    pub creator_tool: String,
    pub create_date: Option<DateTime<Utc>>,
    pub document_id: Option<String>,
    /// Extra `rdf:Description` blocks, written verbatim after ours.
    pub extra_descriptions: Vec<String>,
}

impl Default for XmpPacket {
    fn default() -> Self {
        Self {
            rating: None,
            label: None,
            pick: false,
            keywords: Vec::new(),
            hierarchical_keywords: Vec::new(),
            title: None,
            caption: None,
            headline: None,
            creator: None,
            copyright: None,
            creator_tool: "Open Tether for Mac".into(),
            create_date: None,
            document_id: None,
            extra_descriptions: Vec::new(),
        }
    }
}

/// Lightroom's label names.
pub fn lightroom_label(l: ColorLabel) -> Option<&'static str> {
    match l {
        ColorLabel::Red => Some("Red"),
        ColorLabel::Yellow => Some("Yellow"),
        ColorLabel::Green => Some("Green"),
        ColorLabel::Blue => Some("Blue"),
        ColorLabel::Purple => Some("Purple"),
        ColorLabel::None => None,
    }
}

/// Photo Mechanic colour classes: 1 Winner (red), 2 Winner alt (yellow),
/// 3 Superior (green), 4 Superior alt (blue), 5 Typical (purple)…
pub fn photo_mechanic_class(l: ColorLabel) -> Option<i64> {
    match l {
        ColorLabel::Red => Some(1),
        ColorLabel::Yellow => Some(2),
        ColorLabel::Green => Some(3),
        ColorLabel::Blue => Some(4),
        ColorLabel::Purple => Some(5),
        ColorLabel::None => None,
    }
}

const LABELLED: [ColorLabel; 5] = [
    ColorLabel::Red,
    ColorLabel::Yellow,
    ColorLabel::Green,
    ColorLabel::Blue,
    ColorLabel::Purple,
];

fn iso(d: &DateTime<Utc>) -> String {
    d.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

impl XmpPacket {
    /// Build from a capture's review state plus the user's metadata profile.
    pub fn from_capture(
        capture: &CaptureItem,
        tags: &[String],
        profile: &MetadataProfile,
        session_name: Option<&str>,
    ) -> Self {
        let mut kw: Vec<String> = tags.to_vec();
        if capture.flag == CaptureFlag::Pick {
            kw.push("tether:pick".into());
        }
        if let Some(s) = session_name.filter(|_| profile.session_as_keyword) {
            kw.push(s.to_string());
        }
        let keywords: Vec<String> = kw
            .into_iter()
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        Self {
            rating: Some(if capture.flag == CaptureFlag::Reject {
                -1
            } else {
                capture.rating
            }),
            label: (capture.color_label != ColorLabel::None).then_some(capture.color_label),
            pick: capture.flag == CaptureFlag::Pick,
            keywords,
            hierarchical_keywords: profile
                .hierarchical_root
                .as_ref()
                .map(|root| tags.iter().map(|t| format!("{root}|{t}")).collect())
                .unwrap_or_default(),
            title: None,
            caption: profile.caption_template.as_ref().map(|t| {
                NamingTemplate::new(t.clone()).render_simple(
                    capture,
                    session_name,
                    capture.sequence,
                )
            }),
            headline: session_name.map(str::to_string),
            creator: profile.creator.clone(),
            copyright: profile.copyright_line(Local::now().year()),
            creator_tool: "Open Tether for Mac".into(),
            create_date: Some(capture.captured_at),
            document_id: Some(format!("xmp.did:tether-{}", capture.id)),
            extra_descriptions: Vec::new(),
        }
    }

    pub fn serialized(&self) -> String {
        let alt = |tag: &str, v: &str| {
            format!(
                "   <{tag}><rdf:Alt><rdf:li xml:lang=\"x-default\">{}</rdf:li></rdf:Alt></{tag}>\n",
                esc(v)
            )
        };
        let list = |kind: &str, tag: &str, v: &[String]| {
            if v.is_empty() {
                return String::new();
            }
            let mut s = format!("   <{tag}><rdf:{kind}>\n");
            for x in v {
                s += &format!("    <rdf:li>{}</rdf:li>\n", esc(x));
            }
            s + &format!("   </rdf:{kind}></{tag}>\n")
        };
        let mut body = String::new();
        if let Some(r) = self.rating {
            body += &format!("   <xmp:Rating>{r}</xmp:Rating>\n");
        }
        if let Some(name) = self.label.and_then(lightroom_label) {
            body += &format!("   <xmp:Label>{name}</xmp:Label>\n");
        }
        body += &format!(
            "   <xmp:CreatorTool>{}</xmp:CreatorTool>\n",
            esc(&self.creator_tool)
        );
        if let Some(d) = &self.create_date {
            body += &format!("   <xmp:CreateDate>{}</xmp:CreateDate>\n", iso(d));
        }
        body += &format!(
            "   <xmp:MetadataDate>{}</xmp:MetadataDate>\n",
            iso(&Utc::now())
        );
        if let Some(id) = &self.document_id {
            body += &format!("   <xmpMM:DocumentID>{}</xmpMM:DocumentID>\n", esc(id));
        }
        if let Some(c) = self.label.and_then(photo_mechanic_class) {
            body += &format!("   <photomechanic:ColorClass>{c}</photomechanic:ColorClass>\n");
        }
        body += &format!(
            "   <photomechanic:Tagged>{}</photomechanic:Tagged>\n",
            if self.pick { "True" } else { "False" }
        );
        body += &list("Bag", "dc:subject", &self.keywords);
        body += &list("Bag", "lr:hierarchicalSubject", &self.hierarchical_keywords);
        if let Some(t) = &self.title {
            body += &alt("dc:title", t);
        }
        if let Some(c) = &self.caption {
            body += &alt("dc:description", c);
        }
        if let Some(c) = &self.creator {
            body += &list("Seq", "dc:creator", std::slice::from_ref(c));
        }
        if let Some(r) = &self.copyright {
            body += &alt("dc:rights", r);
            body += "   <xmpRights:Marked>True</xmpRights:Marked>\n";
        }
        if let Some(h) = &self.headline {
            body += &format!("   <photoshop:Headline>{}</photoshop:Headline>\n", esc(h));
        }
        let extras = self.extra_descriptions.concat();
        format!(
            "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n\
<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"Tether\">\n \
<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n  \
<rdf:Description rdf:about=\"\"\n    \
xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"\n    \
xmlns:xmpMM=\"http://ns.adobe.com/xap/1.0/mm/\"\n    \
xmlns:xmpRights=\"http://ns.adobe.com/xap/1.0/rights/\"\n    \
xmlns:dc=\"http://purl.org/dc/elements/1.1/\"\n    \
xmlns:lr=\"http://ns.adobe.com/lightroom/1.0/\"\n    \
xmlns:photoshop=\"http://ns.adobe.com/photoshop/1.0/\"\n    \
xmlns:photomechanic=\"http://ns.camerabits.com/photomechanic/1.0/\">\n\
{body}  </rdf:Description>\n\
{extras} </rdf:RDF>\n\
</x:xmpmeta>\n\
<?xpacket end=\"w\"?>"
        )
    }

    pub fn data(&self) -> Vec<u8> {
        self.serialized().into_bytes()
    }

    /// Lenient parse of an XMP packet (sidecar or embedded) from any of the
    /// tools above.
    pub fn parse(data: &[u8]) -> Result<Self, XmpError> {
        let p = parse_rdf(data)?;
        let mut out = XmpPacket::default();
        if let Some(r) = p
            .values
            .get("xmp:Rating")
            .and_then(|v| v.trim().parse::<i64>().ok())
        {
            out.rating = Some(r);
        }
        if let Some(l) = p.values.get("xmp:Label") {
            out.label = LABELLED
                .into_iter()
                .find(|c| lightroom_label(*c).is_some_and(|n| n.eq_ignore_ascii_case(l)));
        }
        if out.label.is_none() {
            if let Some(c) = p
                .values
                .get("photomechanic:ColorClass")
                .and_then(|v| v.parse::<i64>().ok())
            {
                out.label = LABELLED
                    .into_iter()
                    .find(|l| photo_mechanic_class(*l) == Some(c));
            }
        }
        let subject = p.bags.get("dc:subject").cloned().unwrap_or_default();
        out.pick = p
            .values
            .get("photomechanic:Tagged")
            .map(|v| v.to_lowercase())
            == Some("true".into())
            || subject.iter().any(|s| s == "tether:pick");
        out.keywords = subject.into_iter().filter(|s| s != "tether:pick").collect();
        out.hierarchical_keywords = p
            .bags
            .get("lr:hierarchicalSubject")
            .cloned()
            .unwrap_or_default();
        out.title = p.alts.get("dc:title").cloned();
        out.caption = p.alts.get("dc:description").cloned();
        out.creator = p.bags.get("dc:creator").and_then(|v| v.first().cloned());
        out.copyright = p.alts.get("dc:rights").cloned();
        out.headline = p.values.get("photoshop:Headline").cloned();
        out.creator_tool = p
            .values
            .get("xmp:CreatorTool")
            .cloned()
            .unwrap_or_else(|| "unknown".into());
        out.create_date = p.values.get("xmp:CreateDate").and_then(|v| {
            DateTime::parse_from_rfc3339(v)
                .ok()
                .map(|d| d.with_timezone(&Utc))
                .or_else(|| parse_ptp_datetime(v))
        });
        out.document_id = p.values.get("xmpMM:DocumentID").cloned();
        Ok(out)
    }

    /// What the library should adopt from a file that arrives with metadata
    /// (FTP push, Files import): rating/flag/label; returns the keywords.
    pub fn apply_to(&self, capture: &mut CaptureItem) -> Vec<String> {
        if let Some(r) = self.rating {
            if r < 0 {
                capture.flag = CaptureFlag::Reject;
                capture.rating = 0;
            } else {
                capture.rating = r.min(5);
            }
        }
        if self.pick {
            capture.flag = CaptureFlag::Pick;
        }
        if let Some(l) = self.label {
            capture.color_label = l;
        }
        self.keywords.clone()
    }
}

#[derive(Default)]
struct Rdf {
    values: HashMap<String, String>,
    bags: HashMap<String, Vec<String>>,
    alts: HashMap<String, String>,
    saw_description: bool,
}

/// Minimal XMP/RDF reader: simple elements, `rdf:Bag`/`rdf:Seq` lists,
/// `rdf:Alt` text, and attribute-style values on `rdf:Description`.
fn parse_rdf(data: &[u8]) -> Result<Rdf, XmpError> {
    let mut reader = quick_xml::Reader::from_reader(data);
    let mut out = Rdf::default();
    let mut stack: Vec<String> = Vec::new();
    let mut text = String::new();
    let mut buf = Vec::new();
    let bad = |e: &dyn std::fmt::Display| XmpError::Malformed(e.to_string());

    let start = |name: String,
                 e: &quick_xml::events::BytesStart<'_>,
                 out: &mut Rdf,
                 stack: &mut Vec<String>,
                 text: &mut String|
     -> Result<(), XmpError> {
        if name == "rdf:Description" {
            out.saw_description = true;
            for a in e.attributes() {
                let a = a.map_err(|e| bad(&e))?;
                let k = String::from_utf8_lossy(a.key.as_ref()).to_string();
                if k.contains(':') && !k.starts_with("xmlns") && k != "rdf:about" {
                    let v = a.unescape_value().map_err(|e| bad(&e))?.to_string();
                    out.values.insert(k, v);
                }
            }
        }
        stack.push(name);
        text.clear();
        Ok(())
    };
    let end = |out: &mut Rdf, stack: &mut Vec<String>, text: &mut String| {
        let t = text.trim().to_string();
        let name = stack.last().cloned().unwrap_or_default();
        if name == "rdf:li" && stack.len() >= 3 {
            let container = &stack[stack.len() - 2];
            let owner = stack[stack.len() - 3].clone();
            if container == "rdf:Alt" {
                out.alts.insert(owner, t);
            } else {
                out.bags.entry(owner).or_default().push(t);
            }
        } else if name.contains(':')
            && !name.starts_with("rdf:")
            && !name.starts_with("x:")
            && !t.is_empty()
            && stack.len() >= 2
            && stack[stack.len() - 2] == "rdf:Description"
        {
            out.values.insert(name, t);
        }
        stack.pop();
        text.clear();
    };

    loop {
        match reader.read_event_into(&mut buf).map_err(|e| bad(&e))? {
            Event::Start(e) => {
                let name = String::from_utf8_lossy(e.name().as_ref()).to_string();
                start(name, &e, &mut out, &mut stack, &mut text)?;
            }
            Event::Empty(e) => {
                let name = String::from_utf8_lossy(e.name().as_ref()).to_string();
                start(name, &e, &mut out, &mut stack, &mut text)?;
                end(&mut out, &mut stack, &mut text);
            }
            Event::End(_) => end(&mut out, &mut stack, &mut text),
            Event::Text(t) => text.push_str(&t.unescape().map_err(|e| bad(&e))?),
            Event::CData(t) => text.push_str(&String::from_utf8_lossy(&t)),
            Event::Eof => break,
            _ => {}
        }
        buf.clear();
    }
    if !stack.is_empty() {
        return Err(XmpError::Malformed("unclosed element".into()));
    }
    if !out.saw_description {
        return Err(XmpError::Malformed("no rdf:Description".into()));
    }
    Ok(out)
}

/// Embeds / extracts an XMP packet in a JPEG's APP1 segment (the standard
/// `http://ns.adobe.com/xap/1.0/` marker), replacing any existing one.
pub mod jpeg_xmp {
    use super::{XmpError, XmpPacket};

    pub const HEADER: &[u8] = b"http://ns.adobe.com/xap/1.0/\0";

    fn segment(payload: &[u8]) -> Vec<u8> {
        let len = (payload.len() + 2) as u16;
        let mut seg = vec![0xFF, 0xE1];
        seg.extend_from_slice(&len.to_be_bytes());
        seg.extend_from_slice(payload);
        seg
    }

    pub fn embed(packet: &XmpPacket, jpeg: &[u8]) -> Result<Vec<u8>, XmpError> {
        if jpeg.len() <= 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8 {
            return Err(XmpError::NotJpeg);
        }
        let mut payload = HEADER.to_vec();
        payload.extend(packet.data());
        if payload.len() + 2 > 0xFFFF {
            return Err(XmpError::Malformed(
                "XMP packet too large for one APP1 segment".into(),
            ));
        }
        let mut out = vec![0xFF, 0xD8];
        let mut i = 2;
        let mut inserted = false;
        // Walk the segments before the image data; drop an old XMP APP1, and
        // insert ours after APP0/EXIF (Exif must stay first for many readers).
        while i + 4 <= jpeg.len() && jpeg[i] == 0xFF {
            let marker = jpeg[i + 1];
            if marker == 0xDA || marker == 0xD9 {
                break;
            }
            let len = (jpeg[i + 2] as usize) << 8 | jpeg[i + 3] as usize;
            let seg_end = jpeg.len().min(i + 2 + len);
            let seg = &jpeg[i..seg_end];
            let is_xmp = marker == 0xE1
                && seg.len() > 4 + HEADER.len()
                && &jpeg[i + 4..i + 4 + HEADER.len()] == HEADER;
            let is_app0_or_exif = marker == 0xE0 || (marker == 0xE1 && !is_xmp);
            if !inserted && !is_app0_or_exif {
                out.extend(segment(&payload));
                inserted = true;
            }
            if !is_xmp {
                out.extend_from_slice(seg);
            }
            i = seg_end;
        }
        if !inserted {
            out.extend(segment(&payload));
        }
        out.extend_from_slice(&jpeg[i.min(jpeg.len())..]);
        Ok(out)
    }

    pub fn extract(jpeg: &[u8]) -> Result<XmpPacket, XmpError> {
        if jpeg.len() <= 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8 {
            return Err(XmpError::NotJpeg);
        }
        let mut i = 2;
        while i + 4 <= jpeg.len() && jpeg[i] == 0xFF {
            let marker = jpeg[i + 1];
            if marker == 0xDA || marker == 0xD9 {
                break;
            }
            let len = (jpeg[i + 2] as usize) << 8 | jpeg[i + 3] as usize;
            let seg_end = jpeg.len().min(i + 2 + len);
            if marker == 0xE1
                && seg_end > i + 4 + HEADER.len()
                && &jpeg[i + 4..i + 4 + HEADER.len()] == HEADER
            {
                return XmpPacket::parse(&jpeg[i + 4 + HEADER.len()..seg_end]);
            }
            i = seg_end;
        }
        Err(XmpError::NoPacket)
    }
}

fn default_true() -> bool {
    true
}

/// Who shot it. Lives in workspace memory; applied to every export.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MetadataProfile {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub creator: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub copyright: Option<String>,
    /// Naming-template tokens, e.g. `"{session} – {date}"`.
    #[serde(
        rename = "captionTemplate",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub caption_template: Option<String>,
    /// `"Tether"` → `lr:hierarchicalSubject` `"Tether|hero"`.
    #[serde(
        rename = "hierarchicalRoot",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub hierarchical_root: Option<String>,
    #[serde(rename = "sessionAsKeyword", default = "default_true")]
    pub session_as_keyword: bool,
    #[serde(rename = "embedInJPEG", default = "default_true")]
    pub embed_in_jpeg: bool,
    #[serde(rename = "writeSidecarsForRAW", default = "default_true")]
    pub write_sidecars_for_raw: bool,
    /// Photo Mechanic / Capture One style.
    #[serde(rename = "writeSidecarsForJPEG", default)]
    pub write_sidecars_for_jpeg: bool,
    #[serde(rename = "readIncomingXMP", default = "default_true")]
    pub read_incoming_xmp: bool,
}

impl Default for MetadataProfile {
    fn default() -> Self {
        Self {
            creator: None,
            copyright: None,
            caption_template: None,
            hierarchical_root: Some("Tether".into()),
            session_as_keyword: true,
            embed_in_jpeg: true,
            write_sidecars_for_raw: true,
            write_sidecars_for_jpeg: false,
            read_incoming_xmp: true,
        }
    }
}

impl MetadataProfile {
    /// Copyright line with the year filled in: "© 2026 Brady Jordan".
    pub fn copyright_line(&self, year: i32) -> Option<String> {
        let creator = self.creator.as_deref().filter(|c| !c.is_empty());
        let Some(c) = creator else {
            return self.copyright.clone();
        };
        if let Some(cp) = self.copyright.as_deref().filter(|c| !c.is_empty()) {
            return Some(cp.replace("{year}", &year.to_string()));
        }
        Some(format!("© {year} {c}"))
    }
}
