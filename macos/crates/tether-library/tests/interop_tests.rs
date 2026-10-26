//! XMP, EXIF, naming and layouts, manifests, import plans and catalog
//! read-back (Swift `InteropTests`, `CatalogTests`, `FileImportPlanTests`).

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Datelike, Local, TimeZone, Utc};
use rusqlite::Connection;
use tether_library::interop::catalogs::{self, CatalogKind};
use tether_library::interop::exif;
use tether_library::interop::{
    jpeg_xmp, FileImportPlan, FolderLayout, MetadataProfile, NamingContext, NamingTemplate,
    SessionManifest, XmpPacket,
};
use tether_library::store::database;
use tether_library::{CaptureFlag, CaptureItem, CaptureState, ColorLabel, MediaKind, ShootSession};
use tether_types::TransportKind;

fn when() -> DateTime<Utc> {
    Utc.timestamp_opt(1_792_000_000, 0).unwrap()
}

fn capture(
    name: &str,
    rating: i64,
    flag: CaptureFlag,
    label: ColorLabel,
    kind: MediaKind,
) -> CaptureItem {
    let mut c = CaptureItem::new("s", 7, 7, name, kind, 10, TransportKind::Usb);
    c.captured_at = when();
    c.rating = rating;
    c.flag = flag;
    c.color_label = label;
    c.state = CaptureState::Ready;
    c
}

fn pick(name: &str) -> CaptureItem {
    capture(
        name,
        4,
        CaptureFlag::Pick,
        ColorLabel::Blue,
        MediaKind::Jpeg,
    )
}

// MARK: XMP

#[test]
fn xmp_round_trip_uses_the_conventions_other_tools_read() {
    let profile = MetadataProfile {
        creator: Some("Brady Jordan".into()),
        copyright: Some("© {year} Brady Jordan".into()),
        caption_template: Some("{session} · {date}".into()),
        hierarchical_root: Some("Tether".into()),
        ..Default::default()
    };
    let tags = vec!["hero".to_string(), "cover".to_string()];
    let p = XmpPacket::from_capture(
        &pick("IMG_0007.JPG"),
        &tags,
        &profile,
        Some("Lookbook AW26"),
    );
    let xml = p.serialized();
    for needle in [
        "<xmp:Rating>4</xmp:Rating>",
        "<xmp:Label>Blue</xmp:Label>",
        "<photomechanic:ColorClass>4</photomechanic:ColorClass>",
        "<photomechanic:Tagged>True</photomechanic:Tagged>",
        "<rdf:li>Tether|hero</rdf:li>",
        "<rdf:li>Lookbook AW26</rdf:li>",
        "<?xpacket begin=",
        "<xmpMM:DocumentID>xmp.did:tether-",
    ] {
        assert!(xml.contains(needle), "missing {needle}");
    }
    let local_date = when().with_timezone(&Local).format("%Y-%m-%d").to_string();
    assert!(
        xml.contains(&format!("Lookbook AW26 · {local_date}")),
        "caption template rendered"
    );
    assert!(!xml.contains("{year}"));

    let back = XmpPacket::parse(&p.data()).unwrap();
    assert_eq!(back.rating, Some(4));
    assert_eq!(back.label, Some(ColorLabel::Blue));
    assert!(back.pick);
    let kw: BTreeSet<&str> = back.keywords.iter().map(String::as_str).collect();
    assert_eq!(kw, BTreeSet::from(["hero", "cover", "Lookbook AW26"]));
    assert_eq!(back.hierarchical_keywords, ["Tether|hero", "Tether|cover"]);
    assert_eq!(back.creator.as_deref(), Some("Brady Jordan"));
    assert_eq!(
        back.copyright,
        profile.copyright_line(Local::now().year()),
        "{{year}} is resolved"
    );
    assert_eq!(back.headline.as_deref(), Some("Lookbook AW26"));
    assert_eq!(back.create_date, Some(when()));
}

/// Byte-level compatibility with a sidecar the iOS app wrote (only the
/// MetadataDate differs between runs).
#[test]
fn serialisation_matches_the_swift_output() {
    let p = XmpPacket {
        rating: Some(2),
        keywords: vec!["one".into()],
        creator_tool: "Open Tether for iOS".into(),
        ..Default::default()
    };
    let xml = p.serialized();
    let expected_head = "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"Tether\">\n <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n  <rdf:Description rdf:about=\"\"\n    xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"\n    xmlns:xmpMM=\"http://ns.adobe.com/xap/1.0/mm/\"\n    xmlns:xmpRights=\"http://ns.adobe.com/xap/1.0/rights/\"\n    xmlns:dc=\"http://purl.org/dc/elements/1.1/\"\n    xmlns:lr=\"http://ns.adobe.com/lightroom/1.0/\"\n    xmlns:photoshop=\"http://ns.adobe.com/photoshop/1.0/\"\n    xmlns:photomechanic=\"http://ns.camerabits.com/photomechanic/1.0/\">\n   <xmp:Rating>2</xmp:Rating>\n   <xmp:CreatorTool>Open Tether for iOS</xmp:CreatorTool>\n   <xmp:MetadataDate>";
    assert!(xml.starts_with(expected_head), "{xml}");
    let expected_tail = "</xmp:MetadataDate>\n   <photomechanic:Tagged>False</photomechanic:Tagged>\n   <dc:subject><rdf:Bag>\n    <rdf:li>one</rdf:li>\n   </rdf:Bag></dc:subject>\n  </rdf:Description>\n </rdf:RDF>\n</x:xmpmeta>\n<?xpacket end=\"w\"?>";
    assert!(xml.ends_with(expected_tail), "{xml}");
}

#[test]
fn reject_becomes_minus_one_and_parses_back_as_reject() {
    let p = XmpPacket::from_capture(
        &capture(
            "A.JPG",
            3,
            CaptureFlag::Reject,
            ColorLabel::None,
            MediaKind::Jpeg,
        ),
        &[],
        &MetadataProfile::default(),
        None,
    );
    assert_eq!(p.rating, Some(-1));
    let mut c = capture(
        "A.JPG",
        0,
        CaptureFlag::None,
        ColorLabel::None,
        MediaKind::Jpeg,
    );
    XmpPacket::parse(&p.data()).unwrap().apply_to(&mut c);
    assert_eq!((c.flag, c.rating), (CaptureFlag::Reject, 0));
}

const LIGHTROOM: &str = r#"<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:lr="http://ns.adobe.com/lightroom/1.0/" xmp:Rating="5" xmp:Label="Red" xmp:CreatorTool="Adobe Photoshop Lightroom Classic 13.0">
   <dc:subject><rdf:Bag><rdf:li>studio</rdf:li><rdf:li>headshot</rdf:li></rdf:Bag></dc:subject>
   <lr:hierarchicalSubject><rdf:Bag><rdf:li>Clients|Acme</rdf:li></rdf:Bag></lr:hierarchicalSubject>
   <dc:creator><rdf:Seq><rdf:li>Someone Else</rdf:li></rdf:Seq></dc:creator>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>"#;

#[test]
fn parses_lightroom_and_capture_one_style_sidecars() {
    let p = XmpPacket::parse(LIGHTROOM.as_bytes()).unwrap();
    assert_eq!(p.rating, Some(5));
    assert_eq!(p.label, Some(ColorLabel::Red));
    assert!(!p.pick);
    assert_eq!(p.keywords, ["studio", "headshot"]);
    assert_eq!(p.creator.as_deref(), Some("Someone Else"));
    let mut c = capture(
        "x.jpg",
        0,
        CaptureFlag::None,
        ColorLabel::None,
        MediaKind::Jpeg,
    );
    assert_eq!(p.apply_to(&mut c), ["studio", "headshot"]);
    assert_eq!((c.rating, c.color_label), (5, ColorLabel::Red));
    // Photo Mechanic colour class without a Lightroom label.
    let pm = LIGHTROOM.replace(" xmp:Label=\"Red\"", "").replace(
        "<dc:creator>",
        "<photomechanic:ColorClass xmlns:photomechanic=\"http://ns.camerabits.com/photomechanic/1.0/\">3</photomechanic:ColorClass><dc:creator>",
    );
    assert_eq!(
        XmpPacket::parse(pm.as_bytes()).unwrap().label,
        Some(ColorLabel::Green)
    );
    assert!(XmpPacket::parse(b"<not xml").is_err());
    assert!(XmpPacket::parse(b"<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"></x:xmpmeta>").is_err());
}

#[test]
fn jpeg_embed_replaces_and_keeps_exif_first() {
    let mut jpeg = vec![0xFF, 0xD8];
    jpeg.extend(exif::minimal_jpeg_exif(
        "Canon",
        "EOS R5",
        when(),
        1.0 / 250.0,
        2.8,
        400,
    ));
    jpeg.extend([0xFF, 0xDB, 0x00, 0x04, 0x00, 0x00]); // DQT stub
    jpeg.extend([0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9]); // SOS + "scan" + EOI
    let p1 = XmpPacket {
        rating: Some(2),
        keywords: vec!["one".into()],
        ..Default::default()
    };
    let once = jpeg_xmp::embed(&p1, &jpeg).unwrap();
    assert_eq!(jpeg_xmp::extract(&once).unwrap().rating, Some(2));
    assert_eq!(
        &once[..4],
        &[0xFF, 0xD8, 0xFF, 0xE1],
        "Exif APP1 still first"
    );
    let e = exif::read(&once).unwrap();
    assert_eq!((e.model.as_deref(), e.iso), (Some("EOS R5"), Some(400)));
    let p5 = XmpPacket {
        rating: Some(5),
        ..Default::default()
    };
    let twice = jpeg_xmp::embed(&p5, &once).unwrap();
    assert_eq!(jpeg_xmp::extract(&twice).unwrap().rating, Some(5));
    assert_eq!(
        twice.len() as i64 - once.len() as i64,
        p5.data().len() as i64 - p1.data().len() as i64,
        "old packet replaced, not duplicated"
    );
    assert_eq!(
        &twice[twice.len() - 2..],
        &[0xFF, 0xD9],
        "image data intact"
    );
    assert!(jpeg_xmp::extract(&jpeg).is_err());
    assert!(jpeg_xmp::embed(&p1, &[1, 2, 3]).is_err());
}

#[test]
fn exif_reader() {
    let d = exif::parse_date("2026:10:16 09:41:00").unwrap();
    let mut jpeg = vec![0xFF, 0xD8];
    jpeg.extend(exif::minimal_jpeg_exif(
        "SONY",
        "ILCE-7M4",
        d,
        1.0 / 8000.0,
        1.8,
        100,
    ));
    jpeg.extend([0xFF, 0xD9]);
    let e = exif::read(&jpeg).unwrap();
    assert_eq!(e.camera_line(), "SONY ILCE-7M4");
    assert_eq!(e.exposure_line(), "1/8000  ƒ/1.8  ISO 100");
    assert_eq!(e.date_time_original, Some(d));
    assert!(exif::read(&[0xFF, 0xD8, 0xFF, 0xD9]).is_err());
}

// MARK: Naming, layouts, manifest

#[test]
fn naming_templates_and_safety() {
    let c = capture(
        "IMG_0007.CR3",
        4,
        CaptureFlag::Pick,
        ColorLabel::Blue,
        MediaKind::Raw,
    );
    let render = |p: &str, session: Option<&str>, index: i64| {
        NamingTemplate::new(p).render_simple(&c, session, index)
    };
    assert_eq!(
        render("{session}_{seq:4}", Some("Lookbook AW26"), 7),
        "Lookbook AW26_0007"
    );
    let client = NamingTemplate::new("{client}/{orig}").render(
        &c,
        &NamingContext {
            index: 1,
            client: Some("Acme: Fall"),
            ..Default::default()
        },
    );
    assert_eq!(client, "Acme_ Fall/IMG_0007");
    assert_eq!(
        render("{rating}{label}{pick}{kind}", None, 1),
        "4bluepickraw"
    );
    assert_eq!(render("{seq}", None, 12), "0012");
    assert_eq!(
        render("", None, 1),
        "IMG_0007",
        "empty pattern falls back to the original"
    );
    assert_eq!(
        NamingTemplate::safe("a/b\\c:d*e?f\"g<h>i|j", false),
        "a_b_c_d_e_f_g_h_i_j"
    );
    let c1 = FolderLayout::CaptureOne;
    assert_eq!(c1.directory(&c, Some("AW26"), None), "AW26/Selects");
    assert_eq!(
        c1.directory(
            &capture(
                "x",
                4,
                CaptureFlag::Reject,
                ColorLabel::Blue,
                MediaKind::Jpeg
            ),
            Some("AW26"),
            None
        ),
        "AW26/Trash"
    );
    assert_eq!(
        c1.directory(
            &capture("x", 4, CaptureFlag::None, ColorLabel::Blue, MediaKind::Jpeg),
            Some("AW26"),
            None
        ),
        "AW26/Capture"
    );
    assert_eq!(c1.scaffold(Some("AW26")).len(), 4);
    assert_eq!(
        FolderLayout::ByRating.directory(
            &capture("x", 1, CaptureFlag::Pick, ColorLabel::Blue, MediaKind::Jpeg),
            None,
            None
        ),
        "1 star"
    );
    let year = when()
        .with_timezone(&Local)
        .format("%Y/%Y-%m-%d")
        .to_string();
    assert_eq!(FolderLayout::Dated.directory(&c, None, None), year);
    let r = FolderLayout::CaptureOneSessionRoot;
    assert_eq!(r.manifest_directory(Some("AW26")), "Output");
    assert_eq!(c1.manifest_directory(Some("AW26")), "AW26/Output");
    assert_eq!(
        r.scaffold(Some("AW26")),
        ["Capture", "Selects", "Output", "Trash"]
    );
    assert_eq!(
        serde_json::to_string(&r).unwrap(),
        "\"captureOneSessionRoot\""
    );
}

#[test]
fn manifest_json_and_csv() {
    let mut s = ShootSession::new("Headshots, \"Studio B\"");
    s.workflow_tag = Some("booking-42".into());
    let caps = vec![
        pick("A.JPG"),
        capture(
            "B.CR3",
            0,
            CaptureFlag::None,
            ColorLabel::None,
            MediaKind::Raw,
        ),
    ];
    let tags = HashMap::from([(
        caps[0].id.clone(),
        vec!["hero".to_string(), "a;b".to_string()],
    )]);
    let colls = HashMap::from([(caps[0].id.clone(), vec!["Client selects".to_string()])]);
    let names = HashMap::from([(caps[0].id.clone(), "AW26_0007.JPG".to_string())]);
    let m = SessionManifest::new(&s, &caps, &tags, &colls, &names);
    let csv = m.csv();
    let lines: Vec<&str> = csv.split("\r\n").filter(|l| !l.is_empty()).collect();
    assert_eq!(lines.len(), 3);
    assert!(
        lines[1].starts_with(
            "\"A.JPG\",\"AW26_0007.JPG\",jpeg,4,pick,blue,\"hero;a;b\",\"Client selects\","
        ),
        "{}",
        lines[1]
    );
    let obj: serde_json::Value = serde_json::from_slice(&m.json().unwrap()).unwrap();
    assert_eq!(obj["workflowTag"], "booking-42");
    assert_eq!(obj["rows"].as_array().unwrap().len(), 2);
    assert!(obj["rows"][0]["capturedAt"]
        .as_str()
        .unwrap()
        .ends_with('Z'));
}

// MARK: Import plans

#[test]
fn import_plan_pairs_both_sidecar_spellings_and_skips_junk() {
    let dir = Path::new("/shoot");
    let files: Vec<PathBuf> = [
        "IMG_0002.CR3",
        "IMG_0002.xmp",
        "IMG_0001.JPG",
        "IMG_0001.CR3",
        "IMG_0001.CR3.xmp",
        ".DS_Store",
        "AW26-manifest.json",
        "notes.txt",
        "orphan.xmp",
        "clip.MOV",
    ]
    .iter()
    .map(|n| dir.join(n))
    .collect();
    let plan = FileImportPlan::new(&files);
    let name = |p: &Path| p.file_name().unwrap().to_string_lossy().to_string();
    assert_eq!(
        plan.entries
            .iter()
            .map(|e| name(&e.file))
            .collect::<Vec<_>>(),
        ["clip.MOV", "IMG_0001.CR3", "IMG_0001.JPG", "IMG_0002.CR3"]
    );
    let by_name: HashMap<String, Option<String>> = plan
        .entries
        .iter()
        .map(|e| (name(&e.file), e.sidecar.as_deref().map(name)))
        .collect();
    assert_eq!(
        by_name["IMG_0001.CR3"].as_deref(),
        Some("IMG_0001.CR3.xmp"),
        "darktable-style sidecar"
    );
    assert_eq!(
        by_name["IMG_0002.CR3"].as_deref(),
        Some("IMG_0002.xmp"),
        "Lightroom / Capture One style sidecar"
    );
    assert_eq!(by_name["IMG_0001.JPG"], None);
    let skipped: BTreeSet<String> = plan.skipped.iter().map(|p| name(p)).collect();
    assert_eq!(
        skipped,
        BTreeSet::from([
            "AW26-manifest.json".into(),
            "notes.txt".into(),
            "orphan.xmp".into()
        ])
    );
}

#[test]
fn folder_walk_finds_nested_files() {
    let root = tempfile::tempdir().unwrap();
    let nested = root.path().join("Capture/Day 1");
    std::fs::create_dir_all(&nested).unwrap();
    std::fs::write(nested.join("A.NEF"), [1]).unwrap();
    std::fs::write(root.path().join("B.JPG"), [1]).unwrap();
    std::fs::write(root.path().join(".hidden.JPG"), [1]).unwrap();
    let mut names: Vec<String> = FileImportPlan::files_under(root.path())
        .iter()
        .map(|p| p.file_name().unwrap().to_string_lossy().to_string())
        .collect();
    names.sort();
    assert_eq!(names, ["A.NEF", "B.JPG"]);
}

// MARK: Catalogs

/// The subset of the Lightroom Classic schema the reader uses.
fn make_lightroom_catalog(dir: &Path) -> PathBuf {
    let path = dir.join("Shoots.lrcat");
    let db = database::open(&path.to_string_lossy()).unwrap();
    db.execute_batch(
        "CREATE TABLE AgLibraryRootFolder (id_local INTEGER PRIMARY KEY, absolutePath TEXT, name TEXT);
         CREATE TABLE AgLibraryFolder (id_local INTEGER PRIMARY KEY, pathFromRoot TEXT, rootFolder INTEGER);
         CREATE TABLE AgLibraryFile (id_local INTEGER PRIMARY KEY, baseName TEXT, extension TEXT, folder INTEGER);
         CREATE TABLE Adobe_images (id_local INTEGER PRIMARY KEY, rootFile INTEGER, rating REAL, pick REAL, colorLabels TEXT);
         CREATE TABLE AgLibraryKeyword (id_local INTEGER PRIMARY KEY, name TEXT);
         CREATE TABLE AgLibraryKeywordImage (id_local INTEGER PRIMARY KEY, image INTEGER, tag INTEGER);
         INSERT INTO AgLibraryRootFolder VALUES (1, '/Volumes/SSD/Shoots/', 'Shoots');
         INSERT INTO AgLibraryFolder VALUES (1, 'AW26/', 1);
         INSERT INTO AgLibraryFile VALUES (1, 'IMG_0001', 'CR3', 1), (2, 'AW26_002', 'JPG', 1), (3, 'NOT_OURS', 'NEF', 1);
         INSERT INTO Adobe_images VALUES (10, 1, 4, 1, 'Blue'), (11, 2, NULL, -1, ''), (12, 3, 5, 0, 'Red');
         INSERT INTO AgLibraryKeyword VALUES (1, 'hero'), (2, 'cover');
         INSERT INTO AgLibraryKeywordImage VALUES (1, 10, 1), (2, 10, 2);",
    )
    .unwrap();
    path
}

#[test]
fn reads_lightroom_catalog() {
    let dir = tempfile::tempdir().unwrap();
    let path = make_lightroom_catalog(dir.path());
    let entries = catalogs::read_entries(&path).unwrap();
    let first = entries
        .iter()
        .find(|e| e.filename == "IMG_0001.CR3")
        .unwrap();
    assert_eq!(first.rating, Some(4));
    assert_eq!(first.flag, Some(CaptureFlag::Pick));
    assert_eq!(first.label, Some(ColorLabel::Blue));
    assert_eq!(
        first.keywords.iter().collect::<BTreeSet<_>>(),
        BTreeSet::from([&"hero".to_string(), &"cover".to_string()])
    );
    assert_eq!(first.folder.as_deref(), Some("/Volumes/SSD/Shoots/AW26/"));
    let second = entries
        .iter()
        .find(|e| e.filename == "AW26_002.JPG")
        .unwrap();
    assert_eq!(
        (second.rating, second.flag, second.label),
        (Some(0), Some(CaptureFlag::Reject), Some(ColorLabel::None))
    );
}

#[test]
fn catalog_is_never_touched_and_uncheckpointed_changes_are_read() {
    let dir = tempfile::tempdir().unwrap();
    let path = make_lightroom_catalog(dir.path());
    // Lightroom still has it open: its latest edit is only in the WAL.
    let writer = database::open(&path.to_string_lossy()).unwrap();
    writer.execute_batch("PRAGMA wal_autocheckpoint=0").unwrap();
    writer
        .execute("UPDATE Adobe_images SET rating = 3 WHERE id_local = 12", [])
        .unwrap();
    let suffixed = |s: &str| PathBuf::from(format!("{}{s}", path.display()));
    let files: Vec<PathBuf> = [path.clone(), suffixed("-wal"), suffixed("-shm")]
        .into_iter()
        .filter(|p| p.exists())
        .collect();
    assert!(files.len() >= 2, "the edit sits in a WAL");
    let before: Vec<Vec<u8>> = files.iter().map(|p| std::fs::read(p).unwrap()).collect();

    let entries = catalogs::read_entries(&path).unwrap();
    assert_eq!(
        entries
            .iter()
            .find(|e| e.filename == "NOT_OURS.NEF")
            .unwrap()
            .rating,
        Some(3),
        "reads what is still in the WAL"
    );
    let after: Vec<Vec<u8>> = files.iter().map(|p| std::fs::read(p).unwrap()).collect();
    assert_eq!(before, after, "catalog files unchanged");
    assert!(CatalogKind::is_open_elsewhere(&path));

    let snapshot = database::Snapshot::of(&path).unwrap();
    assert!(
        snapshot
            .connection()
            .execute("INSERT INTO AgLibraryKeyword VALUES (9, 'x')", [])
            .is_err(),
        "query-only"
    );
    let folder = snapshot.folder().to_path_buf();
    drop(snapshot);
    assert!(!folder.exists(), "the private copy is deleted");
    drop(writer);
}

#[test]
fn matches_by_camera_name_and_exported_name() {
    let dir = tempfile::tempdir().unwrap();
    let entries = catalogs::read_entries(&make_lightroom_catalog(dir.path())).unwrap();
    let mut raw = CaptureItem::new(
        "s",
        1,
        1,
        "IMG_0001.CR3",
        MediaKind::Raw,
        0,
        TransportKind::Usb,
    );
    raw.rating = 2;
    let jpeg = CaptureItem::new(
        "s",
        2,
        2,
        "IMG_0002.JPG",
        MediaKind::Jpeg,
        0,
        TransportKind::Usb,
    );
    let exported = HashMap::from([("aw26_002.jpg".to_string(), jpeg.id.clone())]);
    let raw_id = raw.id.clone();
    let result = catalogs::match_catalog(&entries, &[raw.clone(), jpeg.clone()], &exported, |id| {
        if id == raw_id {
            vec!["hero".into()]
        } else {
            vec![]
        }
    });
    assert_eq!(result.unmatched, ["NOT_OURS.NEF"]);
    let r = result
        .changes
        .iter()
        .find(|c| c.capture_id == raw.id)
        .unwrap();
    assert_eq!(
        (r.rating, r.flag, r.label),
        (Some(4), Some(CaptureFlag::Pick), Some(ColorLabel::Blue))
    );
    assert_eq!(
        r.new_keywords,
        ["cover"],
        "only keywords not already on the frame"
    );
    let j = result
        .changes
        .iter()
        .find(|c| c.capture_id == jpeg.id)
        .expect("matched through the exported name");
    assert_eq!(j.flag, Some(CaptureFlag::Reject));
    assert_eq!(j.rating, None, "no change when equal");
}

#[test]
fn reads_capture_one_style_schema_with_variant_table() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("Session.cosessiondb");
    let db = Connection::open(&path).unwrap();
    db.execute_batch(
        "CREATE TABLE ZIMAGE (Z_PK INTEGER PRIMARY KEY, ZIMAGEFILENAME TEXT);
         CREATE TABLE ZVARIANT (Z_PK INTEGER PRIMARY KEY, ZIMAGE INTEGER, ZRATING INTEGER, ZCOLORTAG INTEGER);
         INSERT INTO ZIMAGE VALUES (1, 'IMG_0001.CR3'), (2, 'IMG_0002.CR3');
         INSERT INTO ZVARIANT VALUES (1, 1, 5, 4), (2, 1, 1, 0), (3, 2, 0, 2);",
    )
    .unwrap();
    drop(db);
    let entries = catalogs::read_entries(&path).unwrap();
    assert_eq!(entries.len(), 2, "one entry per image (first variant)");
    let a = entries
        .iter()
        .find(|e| e.filename == "IMG_0001.CR3")
        .unwrap();
    assert_eq!((a.rating, a.label), (Some(5), Some(ColorLabel::Green)));
    let b = entries
        .iter()
        .find(|e| e.filename == "IMG_0002.CR3")
        .unwrap();
    assert_eq!(b.label, None, "orange has no equivalent; left alone");
}

#[test]
fn detects_kinds_and_rejects_others() {
    assert_eq!(
        CatalogKind::detect(Path::new("/a/Shoots.lrcat")),
        Some(CatalogKind::Lightroom)
    );
    assert_eq!(
        CatalogKind::detect(Path::new("/a/Job.cocatalog")),
        Some(CatalogKind::CaptureOne)
    );
    assert_eq!(
        CatalogKind::detect(Path::new("/a/Job.cosessiondb")),
        Some(CatalogKind::CaptureOne)
    );
    assert_eq!(CatalogKind::detect(Path::new("/a/photo.jpg")), None);
    assert!(catalogs::read_entries(Path::new("/a/photo.jpg")).is_err());
}
