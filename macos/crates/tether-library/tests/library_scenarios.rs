//! Power-user "what if" scenarios (Swift `LibraryScenarioTests`). Each test
//! is a story a working photographer would recognise; the assertions are
//! what must stay true.

use std::collections::{BTreeSet, HashSet};
use std::sync::{Arc, Mutex};

use chrono::{Duration, Local, TimeZone, Utc};
use tether_library::delivery::ExportDestination;
use tether_library::library::memory::{ExportMemory, SessionTemplate, ViewState};
use tether_library::library::{
    CaptureFilter, CaptureSort, CaptureStack, Collection, CollectionKind, CommandContext, Commands,
    DateRange, ExportDestinationKey, LibraryError, LiveCaptureHook, ReviewEditor, Selection,
    WorkspaceMemory,
};
use tether_library::{
    CaptureFlag, CaptureItem, CaptureState, ColorLabel, Error, MediaKind, RoutingRules,
    RoutingTarget, SessionStore, ShootSession,
};
use tether_types::{
    CameraCapabilities, CameraIdentity, CameraVendor, CaptureDestination, TransportKind,
};

fn cam(id: &str, vendor: CameraVendor, model: &str, transport: TransportKind) -> CameraIdentity {
    CameraIdentity {
        id: id.into(),
        vendor,
        manufacturer: vendor.display_name().into(),
        model: model.into(),
        serial_number: "1".into(),
        firmware: "1".into(),
        transport,
        capabilities: CameraCapabilities::REMOTE_CAPTURE,
    }
}

struct World {
    store: Arc<SessionStore>,
    memory: Arc<WorkspaceMemory>,
    editor: ReviewEditor,
    a: ShootSession,
    b: ShootSession,
    canon: CameraIdentity,
    sony: CameraIdentity,
}

/// "i minutes ago", but never before midnight.
fn earlier_today(i: i64) -> chrono::DateTime<Utc> {
    let now = Utc::now();
    let midnight = Local
        .from_local_datetime(&Local::now().date_naive().and_hms_opt(0, 0, 0).unwrap())
        .earliest()
        .unwrap()
        .with_timezone(&Utc);
    (now - Duration::minutes(i)).max(midnight + Duration::seconds(i))
}

fn world() -> World {
    let store = Arc::new(SessionStore::in_memory().unwrap());
    let memory = Arc::new(WorkspaceMemory::new(store.clone()));
    let editor = ReviewEditor::new(store.clone(), Some(memory.clone()));
    let canon = cam(
        "canon-R5-1",
        CameraVendor::Canon,
        "EOS R5",
        TransportKind::Usb,
    );
    let sony = cam(
        "sony-A7IV-1",
        CameraVendor::Sony,
        "ILCE-7M4",
        TransportKind::PtpIp,
    );
    let mut a = ShootSession::new("Lookbook AW26");
    a.camera = Some(canon.clone());
    let mut b = ShootSession::new("Headshots Studio B");
    b.camera = Some(sony.clone());
    store.save_session(&a).unwrap();
    store.save_session(&b).unwrap();
    // 60 RAW+JPEG pairs in A (ready), 40 JPEGs in B, 3 still downloading in B.
    let mut all = Vec::new();
    for i in 1..=60i64 {
        for (ext, kind) in [("CR3", MediaKind::Raw), ("JPG", MediaKind::Jpeg)] {
            let seq = i * 2 + if kind == MediaKind::Raw { 0 } else { 1 };
            let mut c = CaptureItem::new(
                &a.id,
                seq,
                i as u32,
                format!("IMG_{i:04}.{ext}"),
                kind,
                10,
                TransportKind::Usb,
            );
            c.received_at = Utc::now() - Duration::days(3) + Duration::seconds(i);
            c.camera_id = Some(canon.id.clone());
            c.state = CaptureState::Ready;
            all.push(c);
        }
    }
    for i in 1..=43i64 {
        let mut c = CaptureItem::new(
            &b.id,
            i,
            1000 + i as u32,
            format!("DSC{i:05}.JPG"),
            MediaKind::Jpeg,
            10,
            TransportKind::PtpIp,
        );
        c.received_at = earlier_today(i);
        c.camera_id = Some(sony.id.clone());
        c.state = if i > 40 {
            CaptureState::Downloading {
                received: 1,
                total: Some(10),
            }
        } else {
            CaptureState::Ready
        };
        all.push(c);
    }
    store.save_captures(&all).unwrap();
    World {
        store,
        memory,
        editor,
        a,
        b,
        canon,
        sony,
    }
}

impl World {
    fn jpegs_a(&self, n: usize) -> Vec<String> {
        let f = CaptureFilter {
            kinds: Some([MediaKind::Jpeg].into()),
            session_ids: Some([self.a.id.clone()].into()),
            ..Default::default()
        };
        self.store
            .captures_matching(&f, CaptureSort::CaptureTimeAscending, None, 0)
            .unwrap()
            .into_iter()
            .take(n)
            .map(|c| c.id)
            .collect()
    }

    fn count(&self, f: CaptureFilter) -> i64 {
        self.store.count_matching(&f).unwrap()
    }

    fn count_in(&self, id: &str) -> i64 {
        self.store
            .count_in_collection(&self.store.collection(id).unwrap().unwrap())
            .unwrap()
    }
}

fn set<T: Ord + Clone>(v: &[T]) -> Option<BTreeSet<T>> {
    Some(v.iter().cloned().collect())
}

fn tags(v: &[&str]) -> Option<BTreeSet<String>> {
    Some(v.iter().map(|s| s.to_string()).collect())
}

#[test]
fn built_in_shelves_are_seeded_and_count_correctly() {
    let w = world();
    let all = w.store.collections().unwrap();
    assert_eq!(
        all.iter().filter(|c| c.is_built_in).count(),
        Collection::built_ins().len()
    );
    assert_eq!(
        w.count_in("builtin.all"),
        120 + 40,
        "downloading frames are not library items yet"
    );
    assert_eq!(w.count_in("builtin.unrated"), 160);
    assert_eq!(
        w.count_in("builtin.today"),
        40,
        "session B shot today, A three days ago"
    );
    assert!(matches!(
        w.store.delete_collection("builtin.picks"),
        Err(Error::Library(LibraryError::BuiltInCollection))
    ));
}

#[test]
fn filter_combinations_translate_to_sql() {
    let w = world();
    w.store.add_tags(&["hero", "cover"], &w.jpegs_a(5)).unwrap();
    w.store.add_tags(&["hero"], &w.jpegs_a(8)).unwrap();
    assert_eq!(
        w.count(CaptureFilter {
            tags_all: tags(&["hero"]),
            ..Default::default()
        }),
        8
    );
    assert_eq!(
        w.count(CaptureFilter {
            tags_all: tags(&["hero", "cover"]),
            ..Default::default()
        }),
        5
    );
    assert_eq!(
        w.count(CaptureFilter {
            tags_any: tags(&["cover", "nope"]),
            ..Default::default()
        }),
        5
    );
    assert_eq!(
        w.count(CaptureFilter {
            kinds: set(&[MediaKind::Raw]),
            ..Default::default()
        }),
        60
    );
    assert_eq!(
        w.count(CaptureFilter {
            camera_ids: tags(&[&w.sony.id]),
            ..Default::default()
        }),
        40
    );
    assert_eq!(
        w.count(CaptureFilter {
            text: Some("headshots".into()),
            ..Default::default()
        }),
        40,
        "text searches the session name too"
    );
    assert_eq!(
        w.count(CaptureFilter {
            text: Some("IMG_0007".into()),
            ..Default::default()
        }),
        2
    );
    assert_eq!(
        w.count(CaptureFilter {
            text: Some("%".into()),
            ..Default::default()
        }),
        0,
        "LIKE wildcards are escaped"
    );
    assert_eq!(
        w.count(CaptureFilter {
            date_range: Some(DateRange::Last7Days),
            ..Default::default()
        }),
        160
    );
    assert_eq!(
        w.count(CaptureFilter {
            exported_to: Some(ExportDestinationKey::Never),
            ..Default::default()
        }),
        160
    );
    let f = CaptureFilter {
        min_rating: Some(4),
        flags: set(&[CaptureFlag::Pick]),
        colors: set(&[ColorLabel::Red, ColorLabel::Blue]),
        tags_all: tags(&["hero"]),
        date_range: Some(DateRange::Today),
        text: Some("x".into()),
        ..Default::default()
    };
    assert_eq!(
        f.summary(),
        "4★+ · Pick · blue, red · #hero · today · \u{201C}x\u{201D}"
    );
    assert!(CaptureFilter::default().is_empty());
    // Paging
    assert_eq!(
        w.store
            .captures_matching(
                &CaptureFilter::default(),
                CaptureSort::Filename,
                Some(25),
                150
            )
            .unwrap()
            .len(),
        10
    );
    // Smart-collection rules round-trip through JSON the way Swift writes them.
    let json = serde_json::to_string(&f).unwrap();
    assert!(json.contains(r#""dateRange":{"today":{}}"#) && json.contains(r#""readyOnly":true"#));
    assert_eq!(serde_json::from_str::<CaptureFilter>(&json).unwrap(), f);
    let between = CaptureFilter {
        date_range: Some(DateRange::Between(
            Utc::now() - Duration::days(1),
            Utc::now(),
        )),
        ..Default::default()
    };
    assert!(serde_json::to_string(&between)
        .unwrap()
        .contains(r#"{"between":{"_0":"#));
}

#[test]
fn stacks_pair_raw_and_jpeg() {
    let w = world();
    let items = w
        .store
        .captures_matching(
            &CaptureFilter {
                session_ids: tags(&[&w.a.id]),
                ..Default::default()
            },
            CaptureSort::CaptureTimeAscending,
            None,
            0,
        )
        .unwrap();
    let stacks = CaptureStack::stack(&items);
    assert_eq!(stacks.len(), 60);
    assert!(stacks
        .iter()
        .all(|s| s.is_pair() && s.top().kind == MediaKind::Jpeg));
    let mixed = CaptureStack::stack(
        &w.store
            .captures_matching(
                &CaptureFilter::default(),
                CaptureSort::SessionThenTime,
                None,
                0,
            )
            .unwrap(),
    );
    assert_eq!(mixed.len(), 100);
}

#[test]
fn bulk_rating_syncs_pairs_and_undo_reverts_the_whole_batch() {
    let w = world();
    let twelve = w.jpegs_a(12);
    let picks = || w.count_in("builtin.picks");
    let four_plus = || {
        w.count(CaptureFilter {
            min_rating: Some(4),
            ..Default::default()
        })
    };
    let red = || {
        w.count(CaptureFilter {
            colors: set(&[ColorLabel::Red]),
            ..Default::default()
        })
    };
    w.editor.rate(&twelve, 4).unwrap();
    assert_eq!(four_plus(), 24, "RAW twins follow their JPEG");
    w.editor.flag(&twelve[..3], CaptureFlag::Pick).unwrap();
    assert_eq!(picks(), 6);
    w.editor.label(&twelve[..2], ColorLabel::Red).unwrap();
    assert_eq!(red(), 2, "labels stay per file");

    assert_eq!(w.editor.undo_title().as_deref(), Some("Label red"));
    w.editor.undo().unwrap();
    assert_eq!(red(), 0);
    w.editor.undo().unwrap();
    assert_eq!(picks(), 0, "one undo clears the whole pick batch");
    w.editor.undo().unwrap();
    assert_eq!(four_plus(), 0);
    assert!(!w.editor.can_undo());
    w.editor.redo().unwrap();
    w.editor.redo().unwrap();
    assert_eq!(four_plus(), 24);
    assert_eq!(picks(), 6);
    // A new edit after undo discards the redo branch.
    w.editor.rate(&twelve[..1], 5).unwrap();
    assert!(!w.editor.can_redo());
    assert!(matches!(
        w.editor.rate(&[], 3),
        Err(Error::Library(LibraryError::NothingSelected))
    ));
}

#[test]
fn manual_and_smart_collections_stay_consistent_across_edits() {
    let w = world();
    let picks = w.jpegs_a(10);
    let client = w
        .editor
        .create_collection(
            "Client selects",
            &picks,
            "rectangle.stack",
            ColorLabel::Blue,
        )
        .unwrap();
    let count = |c: &Collection| w.store.count_in_collection(c).unwrap();
    assert_eq!(count(&client), 10);
    assert_eq!(
        w.store.collection_ids_containing(&picks[0]).unwrap(),
        vec![client.id.clone()]
    );
    w.editor.add_to_collection(&picks[..1], &client.id).unwrap(); // duplicate add is a no-op
    assert_eq!(count(&client), 10);
    // Smart: 4★+ JPEGs from this session, updates live.
    let smart = w
        .editor
        .save_smart_collection(
            "Best of lookbook",
            CaptureFilter {
                min_rating: Some(4),
                kinds: set(&[MediaKind::Jpeg]),
                session_ids: tags(&[&w.a.id]),
                ..Default::default()
            },
            "sparkles.rectangle.stack",
        )
        .unwrap();
    assert_eq!(count(&smart), 0);
    w.editor.rate(&picks[..4], 5).unwrap();
    assert_eq!(count(&smart), 4);
    let red = CaptureFilter {
        colors: set(&[ColorLabel::Red]),
        ..Default::default()
    };
    assert_eq!(
        w.store
            .captures_in_collection(&smart, Some(&red), None, None, 0)
            .unwrap()
            .len(),
        0
    );
    // Hand order survives narrowing/sorting choices.
    let reversed: Vec<String> = picks.iter().rev().cloned().collect();
    w.store.reorder(&reversed, &client.id).unwrap();
    let ids = |v: Vec<CaptureItem>| v.into_iter().map(|c| c.id).collect::<Vec<_>>();
    assert_eq!(
        ids(w
            .store
            .captures_in_collection(&client, None, None, None, 0)
            .unwrap()),
        reversed
    );
    assert_eq!(
        ids(w
            .store
            .captures_in_collection(
                &client,
                None,
                Some(CaptureSort::CaptureTimeAscending),
                None,
                0
            )
            .unwrap()),
        picks
    );
    // Adding to a smart collection is refused clearly.
    assert!(matches!(
        w.editor.add_to_collection(&picks, &smart.id),
        Err(Error::Library(LibraryError::NotManual))
    ));
    // Deleting a capture removes it everywhere.
    w.store.delete_capture(&picks[0]).unwrap();
    assert_eq!(count(&client), 9);
    assert_eq!(count(&smart), 3);
    assert!(w.store.tags(&picks[0]).unwrap().is_empty());
    // Undo of the add never removes frames that were already there.
    let mut extra: Vec<String> = w.jpegs_a(12)[10..].to_vec();
    extra.push(picks[1].clone());
    w.editor.add_to_collection(&extra, &client.id).unwrap();
    w.editor.undo().unwrap();
    assert_eq!(
        count(&client),
        9,
        "picks[1] was present before the add and stays"
    );
    // Deleting the collection leaves the photos alone.
    w.store.delete_collection(&client.id).unwrap();
    assert_eq!(
        w.count(CaptureFilter {
            session_ids: tags(&[&w.a.id]),
            ..Default::default()
        }),
        119,
        "only the deleted frame is gone"
    );
}

#[test]
fn tags_normalise_suggest_and_undo() {
    let w = world();
    let some = w.jpegs_a(6);
    w.editor.add_tags(&["#Hero Shot", "cover"], &some).unwrap();
    assert_eq!(w.store.tags(&some[0]).unwrap(), ["cover", "hero-shot"]);
    w.editor.add_tags(&["cover"], &w.jpegs_a(20)).unwrap();
    assert_eq!(w.store.tag_suggestions("c", 12).unwrap(), ["cover"]);
    assert_eq!(
        w.store.tag_suggestions("", 12).unwrap()[0],
        "cover",
        "most used first"
    );
    assert_eq!(w.memory.get(WorkspaceMemory::RECENTS).tags[0], "cover");
    w.editor.undo().unwrap();
    assert_eq!(
        w.count(CaptureFilter {
            tags_all: tags(&["cover"]),
            ..Default::default()
        }),
        6
    );
    w.editor.remove_tags(&["hero-shot"], &some[..1]).unwrap();
    assert_eq!(w.store.tags(&some[0]).unwrap(), ["cover"]);
    w.editor.undo().unwrap();
    assert_eq!(w.store.tags(&some[0]).unwrap(), ["cover", "hero-shot"]);
}

#[derive(Default)]
struct FakeLive {
    seen: Mutex<Vec<CaptureItem>>,
}

impl LiveCaptureHook for FakeLive {
    fn replace_from_store(&self, items: &[CaptureItem]) {
        self.seen.lock().unwrap().extend(items.iter().cloned());
    }
}

#[test]
fn edits_propagate_to_the_open_session_and_observers() {
    let w = world();
    let live = Arc::new(FakeLive::default());
    w.editor.attach(Some(live.clone()));
    let mut rx = w.editor.subscribe();
    let target = w.jpegs_a(1)[0].clone();
    w.editor.rate(std::slice::from_ref(&target), 3).unwrap();
    let seen = live.seen.lock().unwrap().clone();
    assert_eq!(seen.len(), 2, "the JPEG and its RAW twin");
    assert!(seen.iter().all(|c| c.rating == 3));
    assert!(seen.iter().any(|c| c.kind == MediaKind::Raw));
    let mut changed = false;
    while let Ok(ev) = rx.try_recv() {
        if let tether_library::library::EditorEvent::Changed(ids) = ev {
            changed = ids.contains(&target);
        }
    }
    assert!(changed);
}

#[test]
fn templates_and_camera_memory_shape_the_next_session() {
    let w = world();
    let memory = &w.memory;
    let mut first = ShootSession::new("");
    first.destination = CaptureDestination::Host;
    first.look_id = Some("film-warm".into());
    first.look_strength = 0.8;
    first.show_newest_capture = false;
    first.routing = RoutingRules {
        jpeg: RoutingTarget::Photos,
        raw: RoutingTarget::Ftp,
        auto_export_picks: true,
        ..Default::default()
    };
    first.camera = Some(w.canon.clone());
    memory.learn(&first);
    let d = memory.get(WorkspaceMemory::SESSION_DEFAULTS);
    assert_eq!(d.destination, CaptureDestination::Host);
    assert_eq!(d.look.look_id.as_deref(), Some("film-warm"));
    assert_eq!(memory.camera(&w.canon.id).unwrap().look.strength, 0.8);

    let mut t = memory.template_from(&first, "Lookbook");
    t.tags = vec!["lookbook".into()];
    t.name_pattern = "{date} {name} {camera}".into();
    memory.save_template(&t);
    let mut next = ShootSession::new("");
    let suggested = memory.suggested_template(Some(&w.canon));
    memory.configure(&mut next, suggested.as_ref(), Some(&w.canon), 2);
    assert_eq!(next.destination, CaptureDestination::Host);
    assert!(next.name.ends_with("Lookbook EOS R5"), "{}", next.name);
    assert_eq!(next.routing.raw, RoutingTarget::Ftp);
    assert_eq!(memory.templates()[0].use_count, 1);
    assert_eq!(
        memory.camera(&w.canon.id).unwrap().template_id.as_deref(),
        Some(t.id.as_str())
    );
    assert_eq!(memory.suggested_template(Some(&w.canon)).unwrap().id, t.id);
    // A different camera with no history still gets the most recent template.
    assert_eq!(memory.suggested_template(Some(&w.sony)).unwrap().id, t.id);
    // No template: the remembered defaults apply.
    let mut blank = ShootSession::new("Blank");
    memory.configure(&mut blank, None, None, 1);
    assert_eq!(blank.look_id.as_deref(), Some("film-warm"));
    memory.delete_template(&t.id);
    assert!(memory.templates().is_empty());
    let _ = SessionTemplate::new("x");
}

#[test]
fn view_state_exposure_and_export_memory_persist_across_relaunch() {
    let w = world();
    let memory = &w.memory;
    let v = ViewState {
        filter: CaptureFilter {
            min_rating: Some(3),
            ..Default::default()
        },
        columns: 5,
        scroll_to_capture_id: Some("abc".into()),
        sort: CaptureSort::RatingDescending,
        ..Default::default()
    };
    memory.set_view_state(v, "builtin.picks");
    memory.remember_exposure(&w.sony.id, [("iso", "400")]);
    let mut e = ExportMemory {
        destination: ExportDestination::Ftp {
            destination_id: "nas".into(),
        },
        ..Default::default()
    };
    e.options.include_raw = true;
    e.scope = "selection".into();
    memory.set(WorkspaceMemory::LAST_EXPORT, &e);
    memory.note_search("hero");
    memory.note_search("cover");
    memory.note_search("hero");

    // "Relaunch": a fresh memory over the same store.
    let again = WorkspaceMemory::new(w.store.clone());
    assert_eq!(
        again.get(WorkspaceMemory::LAST_COLLECTION_ID),
        "builtin.picks"
    );
    assert_eq!(again.view_state("builtin.picks").columns, 5);
    assert_eq!(again.view_state("builtin.picks").filter.min_rating, Some(3));
    assert_eq!(
        again.view_state("builtin.all").columns,
        3,
        "unknown views get defaults"
    );
    assert_eq!(
        again
            .camera(&w.sony.id)
            .unwrap()
            .last_exposure
            .get("iso")
            .map(String::as_str),
        Some("400")
    );
    assert_eq!(
        again.get(WorkspaceMemory::LAST_EXPORT).destination,
        ExportDestination::Ftp {
            destination_id: "nas".into()
        }
    );
    assert_eq!(
        again.get(WorkspaceMemory::RECENTS).searches,
        ["hero", "cover"]
    );
    // Camera memory's exposure dictionary is stored the way Swift writes a
    // `[TetherProperty: String]`: a flat key/value array.
    let raw = w.store.setting("memory.cameras").unwrap();
    assert!(raw.contains(r#""lastExposure":["iso","400"]"#), "{raw}");
}

#[test]
fn export_history_is_queryable() {
    let w = world();
    let three = w.jpegs_a(3);
    for id in &three {
        w.store
            .record_export(
                id,
                ExportDestinationKey::Photos,
                "job1",
                Some(&format!("ph-{id}")),
            )
            .unwrap();
    }
    w.store
        .record_export(
            &three[0],
            ExportDestinationKey::Ftp,
            "job2",
            Some("/nas/a.jpg"),
        )
        .unwrap();
    assert_eq!(
        w.count(CaptureFilter {
            exported_to: Some(ExportDestinationKey::Any),
            ..Default::default()
        }),
        3
    );
    assert_eq!(
        w.count(CaptureFilter {
            exported_to: Some(ExportDestinationKey::Ftp),
            ..Default::default()
        }),
        1
    );
    assert_eq!(
        w.count(CaptureFilter {
            exported_to: Some(ExportDestinationKey::Never),
            ..Default::default()
        }),
        157
    );
    assert_eq!(w.store.export_history(&three[0]).unwrap().len(), 2);
    assert_eq!(
        w.store.exported_filenames().unwrap().get("a.jpg"),
        Some(&three[0])
    );
    let s = w.store.library_stats().unwrap();
    assert_eq!((s.captures, s.sessions, s.cameras), (160, 2, 2));
    let _ = &w.b;
}

#[test]
fn selection_math_and_command_availability() {
    let order: Vec<String> = (0..10).map(|i| format!("f{i}")).collect();
    let mut s = Selection::default();
    s.replace("f2");
    s.extend("f5", &order);
    assert_eq!(s.ids(), ["f2", "f3", "f4", "f5"]);
    s.toggle("f3");
    assert_eq!(s.count(), 3);
    s.invert(&order);
    assert_eq!(s.count(), 7);
    assert!(s.contains("f3"));
    s.keep_only(&HashSet::from(["f3".to_string(), "zzz".to_string()]));
    assert_eq!(s.ids(), ["f3"]);
    s.select_all(&order);
    assert_eq!(s.count(), 10);
    s.clear();
    assert!(s.is_empty());

    let none = Commands::available(&CommandContext::default());
    assert!(!none.contains(&Commands::PICK));
    assert!(none.contains(&Commands::SELECT_ALL));
    let two = Commands::available(&CommandContext {
        selection_count: 2,
        can_undo: true,
        ..Default::default()
    });
    assert!(
        two.contains(&Commands::COMPARE)
            && two.contains(&Commands::UNDO)
            && !two.contains(&Commands::COLOR_MATCH)
    );
    let one = Commands::available(&CommandContext {
        selection_count: 1,
        in_collection: Some(Collection::new("x", CollectionKind::Manual)),
        ..Default::default()
    });
    assert!(
        one.contains(&Commands::COLOR_MATCH) && one.contains(&Commands::REMOVE_FROM_COLLECTION)
    );
    let live = Commands::available(&CommandContext {
        in_live_session: true,
        camera_capabilities: CameraCapabilities::REMOTE_CAPTURE,
        ..Default::default()
    });
    assert_eq!(live[0], Commands::CAPTURE);
    assert!(!live.contains(&Commands::LIVE_VIEW));
    let ctx1 = CommandContext {
        selection_count: 1,
        ..Default::default()
    };
    assert_eq!(Commands::search("5", &ctx1)[0].id, "rate.5");
    assert_eq!(
        Commands::search("coll", &ctx1)
            .iter()
            .map(|c| c.id)
            .collect::<Vec<_>>(),
        ["collection.add", "collection.new"]
    );
    assert!(Commands::available(&CommandContext {
        selection_count: 1,
        in_live_session: true,
        ..Default::default()
    })
    .contains(&Commands::END_SESSION));
    assert_eq!(Commands::by_id("flag.pick").unwrap().shortcut, Some("P"));
}

#[test]
fn large_library_queries_stay_fast() {
    let big = SessionStore::in_memory().unwrap();
    let s = ShootSession::new("Wedding");
    big.save_session(&s).unwrap();
    let items: Vec<CaptureItem> = (0..20_000i64)
        .map(|i| {
            let mut c = CaptureItem::new(
                &s.id,
                i,
                i as u32,
                format!("W{i}.JPG"),
                MediaKind::Jpeg,
                1,
                TransportKind::Usb,
            );
            c.state = CaptureState::Ready;
            c.rating = i % 6;
            c.flag = if i % 7 == 0 {
                CaptureFlag::Pick
            } else {
                CaptureFlag::None
            };
            c
        })
        .collect();
    big.save_captures(&items).unwrap();
    let t0 = std::time::Instant::now();
    let expected = (0..20_000).filter(|i| i % 6 >= 4 && i % 7 == 0).count() as i64;
    assert_eq!(
        big.count_matching(&CaptureFilter {
            min_rating: Some(4),
            flags: set(&[CaptureFlag::Pick]),
            ..Default::default()
        })
        .unwrap(),
        expected
    );
    let page = big
        .captures_matching(
            &CaptureFilter {
                min_rating: Some(3),
                ..Default::default()
            },
            CaptureSort::RatingDescending,
            Some(60),
            300,
        )
        .unwrap();
    assert_eq!(page.len(), 60);
    assert!(t0.elapsed().as_secs_f64() < 1.0);
}
