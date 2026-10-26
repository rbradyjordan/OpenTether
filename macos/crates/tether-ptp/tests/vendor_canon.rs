//! Port of `CanonVendorTests.swift`, plus an end-to-end R5 Mark II path
//! (remote mode → host destination → capture → transfer request → download).

mod common;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::*;
use tether_ptp::device::{CameraEvent, FocusResult, NewObject, TetherProperty, VendorHandler};
use tether_ptp::ptp::*;
use tether_ptp::testing::{fail, fake_jpeg, ok};
use tether_ptp::vendors::canon::{self, event, op, prop, AfState, CanonEventRecord, CanonHandler};
use tether_types::{CameraCapabilities as C, CameraVendor, CaptureDestination, LiveViewQuality};

// MARK: Payload builders

fn record(kind: u32, body: &[u8]) -> Vec<u8> {
    let mut b = ByteBuffer::new();
    b.write_u32(8 + body.len() as u32);
    b.write_u32(kind);
    b.write_bytes(body);
    b.into_bytes()
}

fn object_added_ex(handle: u32, storage: u32, format: u16, size: u32, name: &str) -> Vec<u8> {
    let mut body = ByteBuffer::new();
    body.write_u32(handle); // 0x08
    body.write_u32(storage); // 0x0C
    body.write_u16(format); // 0x10
    body.write_u16(0);
    body.write_u32(0);
    body.write_u32(0); // pad to 0x1C
    body.write_u32(size); // 0x1C
    body.write_u32(0x1234); // 0x20 parent
    body.write_u32(0); // 0x24 pad
    body.write_bytes(name.as_bytes());
    body.write_u8(0); // 0x28 name
    record(event::OBJECT_ADDED_EX, body.bytes())
}

/// ObjectAddedEx64: 64-bit size at 0x1C, parent at 0x24, name at 0x2C.
fn object_added_ex64(handle: u32, storage: u32, format: u16, size: u64, name: &str) -> Vec<u8> {
    let mut body = ByteBuffer::new();
    body.write_u32(handle); // 0x08
    body.write_u32(storage); // 0x0C
    body.write_u16(format); // 0x10
    body.write_u16(0);
    body.write_u32(0);
    body.write_u32(0); // pad to 0x1C
    body.write_u64(size); // 0x1C
    body.write_u32(0x77); // 0x24 parent
    body.write_u32(0); // 0x28 pad
    body.write_bytes(name.as_bytes());
    body.write_u8(0); // 0x2C name
    record(event::OBJECT_ADDED_EX64, body.bytes())
}

fn prop_value_changed(p: u32, v: u32) -> Vec<u8> {
    let mut b = ByteBuffer::new();
    b.write_u32(p);
    b.write_u32(v);
    record(event::PROP_VALUE_CHANGED, b.bytes())
}

fn avail_list(p: u32, values: &[u32]) -> Vec<u8> {
    let mut b = ByteBuffer::new();
    b.write_u32(p);
    b.write_u32(3);
    b.write_u32(values.len() as u32);
    values.iter().for_each(|v| b.write_u32(*v));
    record(event::AVAIL_LIST_CHANGED, b.bytes())
}

const TERMINATOR: [u8; 8] = [8, 0, 0, 0, 0, 0, 0, 0];

fn initial_dump() -> Vec<u8> {
    let mut bytes = Vec::new();
    bytes.extend(prop_value_changed(prop::APERTURE, 0x28));
    bytes.extend(prop_value_changed(prop::SHUTTER_SPEED, 0x78));
    bytes.extend(prop_value_changed(prop::ISO, 0x48));
    bytes.extend(prop_value_changed(prop::EXP_COMPENSATION, 0x03));
    bytes.extend(prop_value_changed(prop::WHITE_BALANCE, 1));
    bytes.extend(prop_value_changed(prop::BATTERY_POWER, 2));
    bytes.extend(prop_value_changed(
        prop::CAPTURE_DESTINATION,
        prop::DESTINATION_CARD,
    ));
    bytes.extend(avail_list(prop::APERTURE, &[0x20, 0x28, 0x30]));
    bytes.extend(avail_list(prop::SHUTTER_SPEED, &[0x70, 0x78, 0x80]));
    bytes.extend(avail_list(prop::ISO, &[0x48, 0x50]));
    bytes.extend(TERMINATOR);
    bytes
}

fn transfer_request(kind: u32, handle: u32, format: u16, size: u32, name: Option<&str>) -> Vec<u8> {
    let mut body = ByteBuffer::new();
    body.write_u32(handle); // 0x08
    body.write_u16(format); // 0x0C
    body.write_u16(0);
    body.write_u32(0); // pad to 0x14
    body.write_u32(size); // 0x14
    body.write_u32(0); // 0x18 pad
    match name {
        Some(n) => {
            body.write_bytes(n.as_bytes());
            body.write_u8(0);
        }
        None => body.write_u8(0),
    }
    record(kind, body.bytes())
}

fn handler(info: PtpDeviceInfo) -> CanonHandler {
    CanonHandler::new(idle_engine(&info), info)
}

fn object(e: &CameraEvent) -> &NewObject {
    match e {
        CameraEvent::ObjectAdded(o) => o,
        other => panic!("expected ObjectAdded, got {other:?}"),
    }
}

// MARK: Capabilities / gate

#[test]
fn capabilities_derive_from_operations() {
    let h = handler(canon());
    assert_eq!(h.vendor(), CameraVendor::Canon);
    for c in [
        C::REMOTE_CAPTURE,
        C::SDRAM_CAPTURE,
        C::CARD_CAPTURE,
        C::LIVE_VIEW,
        C::PROPERTY_CONTROL,
        C::PARTIAL_TRANSFER,
        C::AUTOFOCUS,
        C::THUMBNAILS,
        C::BULB_CAPTURE,
    ] {
        assert!(h.capabilities().contains(c), "{c:?}");
    }
    assert!(!h.capabilities().contains(C::RATING));
    assert!(!h.capabilities().contains(C::TOUCH_AUTOFOCUS));
    let old = handler(canon_old());
    assert!(old.capabilities().contains(C::REMOTE_CAPTURE));
    assert!(!old.capabilities().contains(C::LIVE_VIEW));
    assert!(!old.capabilities().contains(C::AUTOFOCUS));
    let r5m2 = handler(canon_r5_mark_ii());
    assert!(r5m2.capabilities().contains(C::TOUCH_AUTOFOCUS));
    assert_eq!(r5m2.event_poll_interval(), Duration::from_millis(200));
}

#[tokio::test]
async fn prepare_sends_remote_mode_event_mode_then_get_event() {
    let rig = Rig::new(canon()).await;
    rig.transport.ok_all();
    rig.transport.on(op::GET_EVENT, |_| ok(initial_dump()));
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    h.prepare().await.unwrap();
    assert_eq!(
        rig.codes(),
        vec![op::SET_REMOTE_MODE, op::SET_EVENT_MODE, op::GET_EVENT]
    );
    assert_eq!(rig.params()[0], vec![1]);
    assert_eq!(rig.params()[1], vec![1]);
    assert_eq!(h.value(prop::APERTURE), Some(0x28));
    assert_eq!(h.available(prop::APERTURE), Some(vec![0x20, 0x28, 0x30]));
}

#[tokio::test]
async fn prepare_without_remote_mode_is_a_vendor_gate() {
    let rig = Rig::new(info("Canon Inc.", "PowerShot", &[0x9116])).await;
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    let e = h.prepare().await.unwrap_err();
    assert!(matches!(e, PtpError::VendorGate(m) if m.contains("PC remote")));
}

#[tokio::test]
async fn prepare_turns_on_olc_events() {
    let rig = Rig::new(canon_r5_mark_ii()).await;
    rig.transport.ok_all();
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    h.prepare().await.unwrap();
    assert_eq!(
        rig.transport.requests_for(op::SET_REQUEST_OLC_INFO_GROUP)[0].parameters,
        vec![0x1FFF]
    );
}

#[tokio::test]
async fn teardown_leaves_event_and_remote_mode() {
    let rig = Rig::new(canon()).await;
    rig.transport.ok_all();
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    h.teardown().await;
    assert_eq!(rig.codes(), vec![op::SET_EVENT_MODE, op::SET_REMOTE_MODE]);
    assert_eq!(rig.params(), vec![vec![0], vec![0]]);
}

// MARK: Capture

#[tokio::test]
async fn capture_two_stage_with_and_without_af() {
    let rig = Rig::new(canon()).await;
    rig.transport.ok_all();
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    h.capture(true).await.unwrap();
    // Queued events are drained first (EOS bodies report busy otherwise).
    assert_eq!(
        rig.codes(),
        vec![
            op::GET_EVENT,
            op::REMOTE_RELEASE_ON,
            op::REMOTE_RELEASE_ON,
            op::REMOTE_RELEASE_OFF,
            op::REMOTE_RELEASE_OFF
        ]
    );
    assert_eq!(
        rig.params(),
        vec![vec![], vec![1, 0], vec![2, 0], vec![2], vec![1]]
    );
    let rig2 = Rig::new(canon()).await;
    rig2.transport.ok_all();
    CanonHandler::new(rig2.engine.clone(), rig2.info.clone())
        .capture(false)
        .await
        .unwrap();
    assert_eq!(rig2.params(), vec![vec![], vec![3, 0], vec![3]]);
}

#[tokio::test]
async fn refused_autofocus_falls_back_to_firing_without_af() {
    let rig = Rig::new(canon()).await;
    rig.transport.ok_all();
    rig.transport.on(op::REMOTE_RELEASE_ON, |r| {
        if r.parameters == [1, 0] {
            fail(ResponseCode::DEVICE_BUSY)
        } else {
            ok(vec![])
        }
    });
    CanonHandler::new(rig.engine.clone(), rig.info.clone())
        .capture(true)
        .await
        .unwrap();
    let presses: Vec<PtpRequest> = rig
        .requests()
        .into_iter()
        .filter(|r| r.code == op::REMOTE_RELEASE_ON || r.code == op::REMOTE_RELEASE_OFF)
        .collect();
    let last = presses.last().unwrap();
    assert_eq!(last.code, op::REMOTE_RELEASE_OFF);
    assert_eq!(last.parameters, vec![3], "fired without AF and let go");
    assert!(
        presses
            .iter()
            .any(|r| r.code == op::REMOTE_RELEASE_OFF && r.parameters == [1]),
        "the refused half-press is released"
    );
}

#[tokio::test]
async fn failed_full_press_releases_the_half_press() {
    let rig = Rig::new(canon()).await;
    rig.transport.ok_all();
    rig.transport.on(op::REMOTE_RELEASE_ON, |r| {
        if r.parameters == [2, 0] {
            fail(ResponseCode::GENERAL_ERROR)
        } else {
            ok(vec![])
        }
    });
    let e = CanonHandler::new(rig.engine.clone(), rig.info.clone())
        .capture(true)
        .await
        .unwrap_err();
    assert_eq!(e.response_code(), Some(ResponseCode::GENERAL_ERROR));
    let offs: Vec<Vec<u32>> = rig
        .transport
        .requests_for(op::REMOTE_RELEASE_OFF)
        .into_iter()
        .map(|r| r.parameters)
        .collect();
    assert_eq!(
        offs,
        vec![vec![2], vec![1]],
        "full press, then half press let go"
    );
}

#[tokio::test]
async fn camera_that_will_not_fire_explains_why() {
    let rig = Rig::new(canon()).await;
    rig.transport.ok_all();
    rig.transport
        .on(op::REMOTE_RELEASE_ON, |_| fail(ResponseCode::DEVICE_BUSY));
    let e = CanonHandler::new(rig.engine.clone(), rig.info.clone())
        .capture(false)
        .await
        .unwrap_err();
    assert!(
        e.to_string().contains("lens"),
        "plain explanation, not DeviceBusy"
    );
    assert_eq!(canon::display(prop::APERTURE, 0), "—");
}

#[tokio::test]
async fn capture_falls_back_to_remote_release() {
    let rig = Rig::new(canon_old()).await;
    rig.transport.ok_all();
    CanonHandler::new(rig.engine.clone(), rig.info.clone())
        .capture(true)
        .await
        .unwrap();
    assert_eq!(rig.codes(), vec![op::REMOTE_RELEASE]);
    let none = Rig::new(info("Canon Inc.", "EOS", &[0x9114])).await;
    let e = CanonHandler::new(none.engine.clone(), none.info.clone())
        .capture(true)
        .await
        .unwrap_err();
    assert!(matches!(e, PtpError::Unsupported(_)));
}

// MARK: Destination

#[tokio::test]
async fn set_capture_destination_writes_eos_property() {
    let rig = Rig::new(canon()).await;
    rig.transport.ok_all();
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    h.set_capture_destination(CaptureDestination::Host)
        .await
        .unwrap();
    assert_eq!(
        rig.requests().last().unwrap().data_out,
        Some(CanonHandler::set_property_payload(
            prop::CAPTURE_DESTINATION,
            prop::DESTINATION_HOST
        ))
    );
    assert_eq!(h.destination(), CaptureDestination::Host);
    let old = CanonHandler::new(rig.engine.clone(), canon_old());
    old.set_capture_destination(CaptureDestination::Both)
        .await
        .unwrap(); // old body lists 0x9107/0x9117 too
    let e = CanonHandler::new(rig.engine.clone(), info("Canon", "EOS", &[0x9114, 0x910F]))
        .set_capture_destination(CaptureDestination::Host)
        .await
        .unwrap_err();
    assert!(e.to_string().contains("memory"));
}

#[tokio::test]
async fn host_destination_reports_pc_capacity_and_reasserts_it_before_capture() {
    let rig = Rig::new(canon_r5_mark_ii()).await;
    rig.transport.ok_all();
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    h.set_capture_destination(CaptureDestination::Host)
        .await
        .unwrap();
    assert_eq!(
        rig.codes(),
        vec![op::SET_DEVICE_PROP_VALUE_EX, op::PC_HDD_CAPACITY]
    );
    assert_eq!(rig.params()[1], vec![0x0FFF_FFFF, 0x0000_1000, 0x0000_0001]);
    h.capture(false).await.unwrap();
    let codes = rig.codes();
    assert_eq!(
        &codes[2..],
        &[
            op::GET_EVENT,
            op::PC_HDD_CAPACITY,
            op::REMOTE_RELEASE_ON,
            op::REMOTE_RELEASE_OFF
        ]
    );
    // Back to the card: no capacity report.
    h.set_capture_destination(CaptureDestination::Card)
        .await
        .unwrap();
    assert_eq!(rig.codes().last(), Some(&op::SET_DEVICE_PROP_VALUE_EX));
}

// MARK: Events

#[test]
fn get_event_parsing_yields_object_added_and_property_changes() {
    let h = handler(canon());
    let mut bytes = object_added_ex(0x0040_0001, 0x0002_0001, 0x3801, 123_456, "IMG_0042.JPG");
    bytes.extend(prop_value_changed(prop::ISO, 0x50));
    bytes.extend(avail_list(prop::ISO, &[0x48, 0x50, 0x58]));
    bytes.extend(record(event::CAMERA_STATUS_CHANGED, &[1, 0, 0, 0]));
    bytes.extend(TERMINATOR);
    bytes.extend(prop_value_changed(prop::ISO, 0x99)); // after the terminator: ignored
    let events = h.ingest(&bytes);
    assert_eq!(events.len(), 4);
    let obj = object(&events[0]);
    assert_eq!(obj.handle, 0x0040_0001);
    assert_eq!(obj.storage_id, 0x0002_0001);
    let oi = obj.info.as_ref().unwrap();
    assert_eq!(oi.filename, "IMG_0042.JPG");
    assert_eq!(oi.object_compressed_size, 123_456);
    assert_eq!(oi.object_format, ObjectFormat::EXIF_JPEG);
    assert_eq!(oi.parent_object, 0x1234);
    assert!(!obj.in_sdram);
    assert_eq!(
        events[1],
        CameraEvent::PropertyChanged(Some(TetherProperty::Iso))
    );
    assert_eq!(
        events[2],
        CameraEvent::PropertyChanged(Some(TetherProperty::Iso))
    );
    assert_eq!(events[3], CameraEvent::CameraBusy(true));
    assert_eq!(h.value(prop::ISO), Some(0x50));
    assert_eq!(h.available(prop::ISO), Some(vec![0x48, 0x50, 0x58]));
}

#[test]
fn object_added_ex64_reads_the_shifted_layout() {
    let h = handler(canon());
    let mut bytes = object_added_ex64(
        0x0050_0002,
        0x0001_0001,
        0xB108,
        5_000_000_000,
        "IMG_0001.CR3",
    );
    bytes.extend(TERMINATOR);
    let events = h.ingest(&bytes);
    let obj = object(&events[0]);
    let oi = obj.info.as_ref().unwrap();
    assert_eq!(oi.filename, "IMG_0001.CR3");
    assert_eq!(oi.parent_object, 0x77);
    assert_eq!(oi.object_compressed_size, u32::MAX, "clamped to 32 bits");
    assert_eq!(oi.object_format, ObjectFormat::CANON_CR3);
    assert!(!obj.in_sdram);
}

#[test]
fn transfer_request_becomes_sdram_object_with_size_and_name() {
    let h = handler(canon());
    let mut bytes = transfer_request(
        event::REQUEST_OBJECT_TRANSFER,
        0x9000_0001,
        0x3801,
        8_765_432,
        Some("IMG_0100.JPG"),
    );
    bytes.extend(TERMINATOR);
    let events = h.ingest(&bytes);
    assert_eq!(events.len(), 1);
    let obj = object(&events[0]);
    assert_eq!(obj.handle, 0x9000_0001);
    assert!(obj.in_sdram);
    let oi = obj.info.as_ref().unwrap();
    assert_eq!(oi.object_compressed_size, 8_765_432);
    assert_eq!(oi.filename, "IMG_0100.JPG");
    assert_eq!(oi.object_format, ObjectFormat::EXIF_JPEG);
}

#[test]
fn nameless_transfer_request_gets_a_name_from_its_format() {
    let h = handler(canon());
    let mut bytes = transfer_request(
        event::REQUEST_OBJECT_TRANSFER64_LFN,
        0x0040_0012,
        0xB108,
        45_000_000,
        None,
    );
    bytes.extend(TERMINATOR);
    let events = h.ingest(&bytes);
    let obj = object(&events[0]);
    assert!(obj.in_sdram);
    let oi = obj.info.as_ref().unwrap();
    assert_eq!(oi.object_compressed_size, 45_000_000);
    assert_eq!(oi.filename, "IMG_0012.CR3");
    assert_eq!(CanonHandler::file_extension(ObjectFormat(0xB103)), "CR2");
    assert_eq!(CanonHandler::file_extension(ObjectFormat(0xB10A)), "HIF");
    assert_eq!(CanonHandler::file_extension(ObjectFormat(0x3000)), "JPG");
}

#[test]
fn sdram_object_is_flagged_when_storage_is_host() {
    let mut bytes = object_added_ex(7, 0, 0x3801, 10, "A.JPG");
    bytes.extend(TERMINATOR);
    let rec = CanonEventRecord::parse(&bytes);
    assert_eq!(rec.len(), 1);
    let obj = CanonHandler::object_added(&rec[0], false, CaptureDestination::Card).unwrap();
    assert!(obj.in_sdram);
    let mut ram = object_added_ex(8, 0x8000_0001, 0x3801, 10, "B.JPG");
    ram.extend(TERMINATOR);
    let obj = CanonHandler::object_added(
        &CanonEventRecord::parse(&ram)[0],
        false,
        CaptureDestination::Card,
    )
    .unwrap();
    assert!(obj.in_sdram, "0x8000xxxx storage is host memory too");
    // Handle 0 is not an object.
    let mut zero = object_added_ex(0, 1, 0x3801, 10, "C.JPG");
    zero.extend(TERMINATOR);
    assert!(CanonHandler::object_added(
        &CanonEventRecord::parse(&zero)[0],
        false,
        CaptureDestination::Card
    )
    .is_none());
}

#[tokio::test]
async fn card_copies_are_skipped_while_shooting_to_the_host() {
    let rig = Rig::new(canon()).await;
    rig.transport.ok_all();
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    h.set_capture_destination(CaptureDestination::Both)
        .await
        .unwrap();
    let mut bytes = object_added_ex(0x10, 0x0002_0001, 0x3801, 100, "IMG_0001.JPG");
    bytes.extend(transfer_request(
        event::REQUEST_OBJECT_TRANSFER,
        0x9000_0010,
        0x3801,
        100,
        Some("IMG_0001.JPG"),
    ));
    bytes.extend(TERMINATOR);
    let events = h.ingest(&bytes);
    assert_eq!(events.len(), 1, "only the transfer request is downloaded");
    assert_eq!(object(&events[0]).handle, 0x9000_0010);
    // Pushed ObjectAddedEx is ignored too while the host gets the file.
    let pushed = h
        .translate(&PtpEvent::new(
            EventCode(event::OBJECT_ADDED_EX as u16),
            [0x10],
        ))
        .await;
    assert_eq!(pushed, None);
}

#[test]
fn other_records_map_to_neutral_events() {
    let h = handler(canon());
    let mut bytes = Vec::new();
    bytes.extend(record(event::OBJECT_REMOVED, &[0x42, 0, 0, 0]));
    bytes.extend(record(event::WILL_SOON_SHUTDOWN, &[0, 0, 0, 0]));
    bytes.extend(record(event::STORE_ADDED, &[1, 0, 1, 0]));
    bytes.extend(record(event::STORAGE_STATUS_CHANGED, &[1, 0, 1, 0]));
    bytes.extend(record(event::SHUTDOWN_TIMER_UPDATED, &[]));
    bytes.extend(record(event::BULB_EXPOSURE_TIME, &[5, 0, 0, 0]));
    bytes.extend(record(event::REQUEST_GET_EVENT, &[]));
    bytes.extend(record(0xC1FF, &[9, 0, 0, 0]));
    bytes.extend(TERMINATOR);
    let events = h.ingest(&bytes);
    assert_eq!(events[0], CameraEvent::ObjectRemoved { handle: 0x42 });
    assert!(matches!(&events[1], CameraEvent::Warning(w) if w.contains("power off")));
    assert_eq!(events[2], CameraEvent::StorageChanged);
    assert_eq!(events[3], CameraEvent::StorageChanged);
    match &events[4] {
        CameraEvent::Raw(e) => {
            assert_eq!(e.code, EventCode(0xC1FF));
            assert_eq!(e.parameters, vec![9]);
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(events.len(), 5);
}

#[tokio::test]
async fn poll_events_returns_pending_then_fresh() {
    let rig = Rig::new(canon()).await;
    rig.transport.ok_all();
    let dumps = Arc::new(Mutex::new(vec![
        {
            let mut d = prop_value_changed(prop::ISO, 0x50);
            d.extend(TERMINATOR);
            d
        },
        {
            let mut d = transfer_request(
                event::REQUEST_OBJECT_TRANSFER64,
                0x9000_0002,
                0xB108,
                10,
                Some("IMG_0002.CR3"),
            );
            d.extend(TERMINATOR);
            d
        },
    ]));
    let d2 = dumps.clone();
    rig.transport.on(op::GET_EVENT, move |_| {
        let mut d = d2.lock().unwrap();
        ok(if d.is_empty() {
            TERMINATOR.to_vec()
        } else {
            d.remove(0)
        })
    });
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    // read_properties drains the first dump and hands its events to the next poll.
    let props = h.read_properties(&[TetherProperty::Iso]).await.unwrap();
    assert_eq!(props[0].display, "200");
    let events = h.poll_events().await.unwrap();
    assert_eq!(
        events[0],
        CameraEvent::PropertyChanged(Some(TetherProperty::Iso))
    );
    assert_eq!(object(&events[1]).handle, 0x9000_0002);
    assert!(h.poll_events().await.unwrap().is_empty());
}

#[tokio::test]
async fn translate_pushed_events() {
    let h = handler(canon());
    let a = h
        .translate(&PtpEvent::new(
            EventCode(event::OBJECT_ADDED_EX as u16),
            [0x55],
        ))
        .await;
    assert_eq!(a, Some(CameraEvent::ObjectAdded(NewObject::new(0x55))));
    let p = h
        .translate(&PtpEvent::new(
            EventCode(event::PROP_VALUE_CHANGED as u16),
            [prop::SHUTTER_SPEED],
        ))
        .await;
    assert_eq!(
        p,
        Some(CameraEvent::PropertyChanged(Some(
            TetherProperty::ShutterSpeed
        )))
    );
    let std = h
        .translate(&PtpEvent::new(EventCode::OBJECT_ADDED, [0x66]))
        .await;
    assert_eq!(std, Some(CameraEvent::ObjectAdded(NewObject::new(0x66))));
    let t = h
        .translate(&PtpEvent::new(
            EventCode(event::REQUEST_OBJECT_TRANSFER64_LFN as u16),
            [0x77],
        ))
        .await;
    assert_eq!(
        t,
        Some(CameraEvent::ObjectAdded(NewObject {
            in_sdram: true,
            ..NewObject::new(0x77)
        }))
    );
    let poll = h
        .translate(&PtpEvent::new(
            EventCode(event::REQUEST_GET_EVENT as u16),
            [],
        ))
        .await;
    assert_eq!(poll, None);
    let busy = h
        .translate(&PtpEvent::new(
            EventCode(event::CAMERA_STATUS_CHANGED as u16),
            [0],
        ))
        .await;
    assert_eq!(busy, Some(CameraEvent::CameraBusy(false)));
}

// MARK: Properties

#[tokio::test]
async fn property_read_display_and_write_round_trip() {
    let rig = Rig::new(canon()).await;
    rig.transport.ok_all();
    rig.transport.on(op::GET_EVENT, |_| ok(initial_dump()));
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    h.prepare().await.unwrap();
    let props = h
        .read_properties(&[
            TetherProperty::Aperture,
            TetherProperty::ShutterSpeed,
            TetherProperty::Iso,
            TetherProperty::ExposureCompensation,
            TetherProperty::WhiteBalance,
            TetherProperty::BatteryLevel,
            TetherProperty::CaptureDestination,
        ])
        .await
        .unwrap();
    let by = |p: TetherProperty| props.iter().find(|d| d.property == p).unwrap();
    let displays = |p: TetherProperty| -> Vec<String> {
        by(p).choices().iter().map(|c| c.display.clone()).collect()
    };
    assert_eq!(by(TetherProperty::Aperture).display, "ƒ/4");
    assert_eq!(
        displays(TetherProperty::Aperture),
        ["ƒ/2.8", "ƒ/4", "ƒ/5.6"]
    );
    assert_eq!(by(TetherProperty::ShutterSpeed).display, "1/250");
    assert_eq!(
        displays(TetherProperty::ShutterSpeed),
        ["1/125", "1/250", "1/500"]
    );
    assert_eq!(by(TetherProperty::Iso).display, "100");
    assert_eq!(by(TetherProperty::ExposureCompensation).display, "+1/3");
    assert_eq!(by(TetherProperty::WhiteBalance).display, "Daylight");
    assert_eq!(by(TetherProperty::BatteryLevel).display, "100%");
    assert!(!by(TetherProperty::BatteryLevel).is_writable);
    assert!(by(TetherProperty::Aperture).is_writable);
    assert_eq!(
        displays(TetherProperty::CaptureDestination),
        ["Card only", "Mac only (no card)", "Card + Mac"]
    );
    // Write a choice's raw value straight back.
    let choice = by(TetherProperty::Aperture).choices()[0].raw.clone();
    h.write_property(TetherProperty::Aperture, choice)
        .await
        .unwrap();
    let set = rig
        .transport
        .requests_for(op::SET_DEVICE_PROP_VALUE_EX)
        .pop()
        .unwrap();
    assert_eq!(
        set.data_out.unwrap(),
        vec![0x0C, 0, 0, 0, 0x01, 0xD1, 0, 0, 0x20, 0, 0, 0]
    );
    assert_eq!(h.value(prop::APERTURE), Some(0x20));
    // Read-only and unmapped properties are refused; strings are not numbers.
    assert!(h
        .write_property(TetherProperty::BatteryLevel, PtpValue::UInt32(1))
        .await
        .is_err());
    assert!(h
        .write_property(TetherProperty::ImageSize, PtpValue::UInt32(1))
        .await
        .is_err());
    assert!(h
        .write_property(TetherProperty::Iso, PtpValue::String("x".into()))
        .await
        .is_err());
    // Writing the destination through the property updates the handler.
    h.write_property(
        TetherProperty::CaptureDestination,
        PtpValue::UInt32(prop::DESTINATION_BOTH),
    )
    .await
    .unwrap();
    assert_eq!(h.destination(), CaptureDestination::Both);
}

#[tokio::test]
async fn drive_mode_metering_and_focus_mode_come_from_the_event_cache() {
    let rig = Rig::new(canon()).await;
    rig.transport.ok_all();
    let mut dump = prop_value_changed(prop::DRIVE_MODE, 0x01);
    dump.extend(avail_list(prop::DRIVE_MODE, &[0x00, 0x01, 0x04]));
    dump.extend(prop_value_changed(prop::METERING_MODE, 3));
    dump.extend(prop_value_changed(
        prop::FOCUS_MODE,
        canon::FOCUS_MODE_SERVO,
    ));
    dump.extend(prop_value_changed(prop::COLOR_TEMPERATURE, 5200));
    dump.extend(TERMINATOR);
    rig.transport.on(op::GET_EVENT, move |_| ok(dump.clone()));
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    let props = h
        .read_properties(&[
            TetherProperty::DriveMode,
            TetherProperty::MeteringMode,
            TetherProperty::FocusMode,
            TetherProperty::ColorTemperature,
            TetherProperty::LensName, // never reported: skipped
        ])
        .await
        .unwrap();
    assert_eq!(props.len(), 4);
    assert_eq!(props[0].property, TetherProperty::DriveMode);
    assert_eq!(props[0].choices().len(), 3);
    assert_eq!(props[0].current_choice_index(), Some(1));
    assert_eq!(props[3].display, "5200 K");
    h.write_property(TetherProperty::DriveMode, PtpValue::UInt32(4))
        .await
        .unwrap();
    assert_eq!(
        rig.requests().last().unwrap().data_out,
        Some(CanonHandler::set_property_payload(prop::DRIVE_MODE, 4))
    );
}

#[test]
fn value_tables() {
    use canon::display;
    assert_eq!(display(prop::APERTURE, 0x20), "ƒ/2.8");
    assert_eq!(display(prop::APERTURE, 0x18), "ƒ/2");
    assert_eq!(display(prop::APERTURE, 0x99), "ƒ/?(0x99)");
    assert_eq!(display(prop::SHUTTER_SPEED, 0xA0), "1/8000");
    assert_eq!(display(prop::SHUTTER_SPEED, 0x10), "30\"");
    assert_eq!(display(prop::SHUTTER_SPEED, 0x0C), "Bulb");
    assert_eq!(display(prop::SHUTTER_SPEED, 0x3B), "0.8\"");
    assert_eq!(display(prop::SHUTTER_SPEED, 0x01), "?(0x01)");
    assert_eq!(display(prop::ISO, 0x00), "Auto");
    assert_eq!(display(prop::ISO, 0x80), "12800");
    assert_eq!(display(prop::ISO, 0x01), "ISO ?(0x01)");
    assert_eq!(display(prop::WHITE_BALANCE, 23), "Auto (white priority)");
    assert_eq!(display(prop::WHITE_BALANCE, 99), "WB 99");
    assert_eq!(display(prop::BATTERY_POWER, 4), "75%");
    assert_eq!(display(prop::BATTERY_POWER, 7), "7%");
    assert_eq!(display(prop::CAPTURE_DESTINATION, 4), "Mac only (no card)");
    assert_eq!(display(prop::CAPTURE_DESTINATION, 2), "Destination 2");
    assert_eq!(display(prop::DRIVE_MODE, 4), "4");
    assert_eq!(canon::exposure_compensation(0xF8), "-1");
    assert_eq!(canon::exposure_compensation(0x0D), "+1 2/3");
    assert_eq!(canon::exposure_compensation(0xFC), "-1/2");
    assert_eq!(canon::exposure_compensation(0), "0");
}

// MARK: Transfer

#[tokio::test]
async fn sdram_fetch_uses_standard_partial_object_then_transfer_complete() {
    let rig = Rig::new(canon()).await;
    let payload: Vec<u8> = (0..3000u32).map(|i| (i & 0xFF) as u8).collect();
    let p2 = payload.clone();
    rig.transport
        .on(OperationCode::GET_PARTIAL_OBJECT, move |r| {
            let (off, want) = (r.parameters[1] as usize, r.parameters[2] as usize);
            ok(p2[off..(off + want).min(p2.len())].to_vec())
        });
    rig.transport.on(op::TRANSFER_COMPLETE, |_| ok(vec![]));
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    let info = PtpObjectInfo {
        storage_id: 0,
        object_compressed_size: payload.len() as u32,
        filename: "IMG_0001.JPG".into(),
        ..Default::default()
    };
    let seen = Arc::new(Mutex::new(Vec::new()));
    let s2 = seen.clone();
    let progress: ProgressFn = Arc::new(move |a, b| s2.lock().unwrap().push((a, b)));
    let (oi, data) = h
        .fetch_object(
            &NewObject {
                handle: 0x42,
                storage_id: 0,
                info: Some(info),
                in_sdram: true,
            },
            Some(progress),
        )
        .await
        .unwrap();
    assert_eq!(data, payload);
    assert_eq!(oi.filename, "IMG_0001.JPG");
    assert_eq!(
        rig.transport
            .requests_for(OperationCode::GET_PARTIAL_OBJECT)[0]
            .parameters,
        vec![0x42, 0, 3000]
    );
    assert!(rig
        .transport
        .requests_for(op::GET_PARTIAL_OBJECT_EX)
        .is_empty());
    assert_eq!(rig.codes().last(), Some(&op::TRANSFER_COMPLETE));
    assert_eq!(rig.params().last().unwrap(), &vec![0x42]);
    assert_eq!(seen.lock().unwrap().last(), Some(&(3000, Some(3000))));
}

#[tokio::test]
async fn large_sdram_fetch_reads_one_megabyte_chunks() {
    let rig = Rig::new(canon()).await;
    let total = (1 << 20) * 2 + 5;
    rig.transport.on(OperationCode::GET_PARTIAL_OBJECT, |r| {
        ok(vec![0xAB; r.parameters[2] as usize])
    });
    rig.transport.ok_all();
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    let info = PtpObjectInfo {
        object_compressed_size: total,
        filename: "IMG_0003.CR3".into(),
        ..Default::default()
    };
    let (_, data) = h
        .fetch_object(
            &NewObject {
                handle: 9,
                storage_id: 0,
                info: Some(info),
                in_sdram: true,
            },
            None,
        )
        .await
        .unwrap();
    assert_eq!(data.len(), total as usize);
    let reads: Vec<Vec<u32>> = rig
        .transport
        .requests_for(OperationCode::GET_PARTIAL_OBJECT)
        .into_iter()
        .map(|r| r.parameters)
        .collect();
    assert_eq!(
        reads,
        vec![
            vec![9, 0, 1 << 20],
            vec![9, 1 << 20, 1 << 20],
            vec![9, 2 << 20, 5]
        ]
    );
}

#[tokio::test]
async fn bodies_without_standard_partial_use_get_partial_object_ex() {
    let mut info_no_std = canon();
    info_no_std
        .operations_supported
        .retain(|o| *o != OperationCode::GET_PARTIAL_OBJECT);
    let rig = Rig::new(info_no_std).await;
    rig.transport.on(op::GET_PARTIAL_OBJECT_EX, |r| {
        ok(vec![1; r.parameters[2] as usize])
    });
    rig.transport.ok_all();
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    let info = PtpObjectInfo {
        object_compressed_size: 10,
        ..Default::default()
    };
    h.fetch_object(
        &NewObject {
            handle: 5,
            storage_id: 0,
            info: Some(info),
            in_sdram: true,
        },
        None,
    )
    .await
    .unwrap();
    assert_eq!(
        rig.codes(),
        vec![op::GET_PARTIAL_OBJECT_EX, op::TRANSFER_COMPLETE]
    );
}

#[tokio::test]
async fn sdram_fetch_without_size_asks_object_info_and_still_closes_transfer() {
    let rig = Rig::new(canon()).await;
    rig.transport.on(OperationCode::GET_OBJECT_INFO, |_| {
        ok(PtpObjectInfo {
            object_compressed_size: 4,
            filename: "IMG_0009.JPG".into(),
            ..Default::default()
        }
        .encoded())
    });
    rig.transport
        .on(OperationCode::GET_PARTIAL_OBJECT, |_| ok(vec![1, 2, 3, 4]));
    rig.transport.ok_all();
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    let (oi, data) = h
        .fetch_object(
            &NewObject {
                in_sdram: true,
                ..NewObject::new(0x99)
            },
            None,
        )
        .await
        .unwrap();
    assert_eq!(oi.filename, "IMG_0009.JPG");
    assert_eq!(data, vec![1, 2, 3, 4]);
    assert_eq!(
        rig.transport.requests_for(OperationCode::GET_OBJECT_INFO)[0].timeout,
        Duration::from_secs(5)
    );
    // A memory object the body won't describe: the transfer is closed anyway.
    let rig2 = Rig::new(canon()).await;
    rig2.transport.ok_all();
    let h2 = CanonHandler::new(rig2.engine.clone(), rig2.info.clone());
    let e = h2
        .fetch_object(
            &NewObject {
                in_sdram: true,
                ..NewObject::new(0x98)
            },
            None,
        )
        .await
        .unwrap_err();
    assert!(e.to_string().contains("how big"));
    assert_eq!(rig2.codes().last(), Some(&op::TRANSFER_COMPLETE));
}

#[tokio::test]
async fn failed_sdram_fetch_still_releases_the_camera() {
    let rig = Rig::new(canon()).await;
    rig.transport
        .on(OperationCode::GET_PARTIAL_OBJECT, |_| ok(vec![]));
    rig.transport.on(op::TRANSFER_COMPLETE, |_| ok(vec![]));
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    let info = PtpObjectInfo {
        object_compressed_size: 3000,
        filename: "IMG_0002.JPG".into(),
        ..Default::default()
    };
    let r = h
        .fetch_object(
            &NewObject {
                handle: 0x43,
                storage_id: 0,
                info: Some(info),
                in_sdram: true,
            },
            None,
        )
        .await;
    assert!(r.is_err(), "expected the empty read to fail");
    assert_eq!(rig.codes().last(), Some(&op::TRANSFER_COMPLETE));
    assert_eq!(rig.params().last().unwrap(), &vec![0x43]);
}

#[tokio::test]
async fn card_objects_download_through_the_generic_path() {
    let rig = Rig::new(canon()).await;
    let jpeg = fake_jpeg(100);
    let j2 = jpeg.clone();
    rig.transport.on(OperationCode::GET_OBJECT_INFO, |_| {
        ok(PtpObjectInfo {
            object_compressed_size: 100,
            filename: "IMG_0005.JPG".into(),
            ..Default::default()
        }
        .encoded())
    });
    rig.transport
        .on(OperationCode::GET_PARTIAL_OBJECT, move |_| ok(j2.clone()));
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    let (oi, data) = h.fetch_object(&NewObject::new(5), None).await.unwrap();
    assert_eq!(oi.filename, "IMG_0005.JPG");
    assert_eq!(data, jpeg);
    assert!(!rig.codes().contains(&op::TRANSFER_COMPLETE));
}

/// The whole R5 Mark II tether loop: connect gate, shoot to the Mac,
/// the body announces the capture, we download it and release the card.
#[tokio::test]
async fn r5_mark_ii_shoot_to_host_end_to_end() {
    let rig = Rig::new(canon_r5_mark_ii()).await;
    let raw: Vec<u8> = (0..2500u32).map(|i| (i % 251) as u8).collect();
    let dumps: Arc<Mutex<Vec<Vec<u8>>>> = Arc::new(Mutex::new(vec![initial_dump()]));
    let d2 = dumps.clone();
    rig.transport.on(op::GET_EVENT, move |_| {
        let mut d = d2.lock().unwrap();
        ok(if d.is_empty() {
            TERMINATOR.to_vec()
        } else {
            d.remove(0)
        })
    });
    let d3 = dumps.clone();
    let size = raw.len() as u32;
    rig.transport.on(op::REMOTE_RELEASE_OFF, move |r| {
        // The body reports the capture once the shutter is released.
        if r.parameters == [3] {
            let mut rec = transfer_request(
                event::REQUEST_OBJECT_TRANSFER64_LFN,
                0x9001_0021,
                0xB108,
                size,
                None,
            );
            rec.extend(record(event::CAMERA_STATUS_CHANGED, &[0, 0, 0, 0]));
            rec.extend(TERMINATOR);
            d3.lock().unwrap().push(rec);
        }
        ok(vec![])
    });
    let r2 = raw.clone();
    rig.transport
        .on(OperationCode::GET_PARTIAL_OBJECT, move |r| {
            let (off, want) = (r.parameters[1] as usize, r.parameters[2] as usize);
            ok(r2[off..(off + want).min(r2.len())].to_vec())
        });
    rig.transport.ok_all();

    tether_ptp::install_built_ins();
    let h = tether_ptp::VendorRegistry::make_handler(
        rig.engine.clone(),
        rig.info.clone(),
        tether_types::TransportKind::Usb,
    );
    assert!(tether_ptp::device::handler_is::<CanonHandler>(h.as_ref()));
    h.prepare().await.unwrap();
    h.set_capture_destination(CaptureDestination::Host)
        .await
        .unwrap();
    h.capture(false).await.unwrap();
    let events = h.poll_events().await.unwrap();
    let obj = events
        .iter()
        .find_map(|e| match e {
            CameraEvent::ObjectAdded(o) => Some(o.clone()),
            _ => None,
        })
        .expect("capture announced");
    assert!(events.contains(&CameraEvent::CameraBusy(false)));
    assert!(obj.in_sdram);
    assert_eq!(obj.info.as_ref().unwrap().filename, "IMG_0021.CR3");
    let (oi, data) = h.fetch_object(&obj, None).await.unwrap();
    assert_eq!(data, raw);
    assert_eq!(oi.media_kind(), MediaKind::Raw);
    let codes = rig.codes();
    assert_eq!(codes.last(), Some(&op::TRANSFER_COMPLETE));
    assert_eq!(rig.params().last().unwrap(), &vec![0x9001_0021]);
    // Gate order: remote mode, event mode, OLC request, first dump.
    assert_eq!(
        &codes[..4],
        &[
            op::SET_REMOTE_MODE,
            op::SET_EVENT_MODE,
            op::SET_REQUEST_OLC_INFO_GROUP,
            op::GET_EVENT
        ]
    );
    h.teardown().await;
    assert_eq!(rig.codes().last(), Some(&op::SET_REMOTE_MODE));
}

// MARK: Live view

fn view_finder_payload(jpeg: &[u8]) -> Vec<u8> {
    let mut b = ByteBuffer::new();
    b.write_u32(8 + 4);
    b.write_u32(7);
    b.write_u32(0xAAAA_AAAA); // some other record
    b.write_u32(8 + jpeg.len() as u32);
    b.write_u32(1);
    b.write_bytes(jpeg);
    b.into_bytes()
}

#[tokio::test]
async fn live_view_sets_evf_and_extracts_jpeg_record() {
    let rig = Rig::new(canon()).await;
    rig.transport.ok_all();
    let jpeg = fake_jpeg(200);
    let payload = view_finder_payload(&jpeg);
    rig.transport
        .on(op::GET_VIEW_FINDER_DATA, move |_| ok(payload.clone()));
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    assert_eq!(
        h.next_live_view_frame().await.unwrap().map(|f| f.sequence),
        None
    );
    h.start_live_view(LiveViewQuality::Medium).await.unwrap();
    let reqs = rig.requests();
    assert_eq!(
        reqs[0].data_out,
        Some(CanonHandler::set_property_payload(prop::EVF_MODE, 1))
    );
    assert_eq!(
        reqs[1].data_out,
        Some(CanonHandler::set_property_payload(
            prop::EVF_OUTPUT_DEVICE,
            2
        ))
    );
    let frame = h.next_live_view_frame().await.unwrap().unwrap();
    assert_eq!(frame.jpeg, jpeg);
    assert_eq!(frame.sequence, 1);
    let vf = &rig.transport.requests_for(op::GET_VIEW_FINDER_DATA)[0];
    assert_eq!(vf.parameters, vec![0x0010_0000]);
    assert!(!vf.retries_busy, "busy means no frame yet, not retry");
    h.stop_live_view().await;
    assert_eq!(
        rig.requests().last().unwrap().data_out,
        Some(CanonHandler::set_property_payload(
            prop::EVF_OUTPUT_DEVICE,
            0
        ))
    );
}

#[tokio::test]
async fn live_view_not_ready_returns_no_frame_and_errors_pass_through() {
    let rig = Rig::new(canon()).await;
    rig.transport.ok_all();
    let codes = Arc::new(Mutex::new(vec![
        canon::NOT_READY,
        ResponseCode::DEVICE_BUSY,
        ResponseCode::ACCESS_DENIED,
        ResponseCode::GENERAL_ERROR,
    ]));
    rig.transport.on(op::GET_VIEW_FINDER_DATA, move |_| {
        fail(codes.lock().unwrap().remove(0))
    });
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    h.start_live_view(LiveViewQuality::Low).await.unwrap();
    for _ in 0..3 {
        assert!(h.next_live_view_frame().await.unwrap().is_none());
    }
    let e = h.next_live_view_frame().await.unwrap_err();
    assert_eq!(e.response_code(), Some(ResponseCode::GENERAL_ERROR));
    // Without a record stream the SOI scan still finds the JPEG.
    let bare = fake_jpeg(50);
    let mut wrapped = vec![0u8; 3];
    wrapped.extend(&bare);
    assert_eq!(CanonHandler::view_finder_jpeg(&wrapped), Some(bare));
}

#[tokio::test]
async fn live_view_unsupported_on_old_bodies() {
    let rig = Rig::new(canon_old()).await;
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    assert!(matches!(
        h.start_live_view(LiveViewQuality::High).await,
        Err(PtpError::Unsupported(_))
    ));
}

#[tokio::test]
async fn live_view_asks_for_focus_info_to_learn_the_af_space() {
    let rig = Rig::new(canon_r5_mark_ii()).await;
    rig.transport.ok_all();
    // FocusInfoEx blob at byte 12: size, halfsize, version, points, in use, sizeX, sizeY.
    let mut blob = ByteBuffer::new();
    blob.write_u32(prop::FOCUS_INFO_EX);
    blob.write_u32(40); // 12: size
    blob.write_u16(0); // 16: halfsize
    blob.write_u16(1); // 18: version
    blob.write_u16(1); // 20: points
    blob.write_u16(1); // 22: in use
    blob.write_u16(6000); // 24: sizeX
    blob.write_u16(4000); // 26: sizeY
    blob.write_u32(0); // 28..32
    blob.write_bytes(&[0; 8]); // 32: one point
    blob.write_u8(1); // 40: in-focus mask
    let mut dump = record(event::PROP_VALUE_CHANGED, blob.bytes());
    dump.extend(TERMINATOR);
    let rec = CanonEventRecord::parse(&dump);
    assert!(CanonHandler::focus_info_has_focused_points(&rec[0]));
    rig.transport.on(op::GET_EVENT, move |_| ok(dump.clone()));
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    h.start_live_view(LiveViewQuality::Medium).await.unwrap();
    assert_eq!(
        rig.transport.requests_for(op::REQUEST_DEVICE_PROP_VALUE)[0].parameters,
        vec![prop::FOCUS_INFO_EX]
    );
    assert_eq!(h.af_coordinate_space(), Some((6000, 4000)));
}

// MARK: Touch AF

/// OLCInfoChanged for layout 0x14 (R5 Mark II) carrying focus info
/// `result`/`running` (libgphoto2 traces), optionally after a 0x0001 field.
fn olc_focus(result: u8, running: u8, with_leading_field: bool) -> Vec<u8> {
    let mask: u16 = if with_leading_field { 0x0101 } else { 0x0100 };
    let mut fields = Vec::new();
    if with_leading_field {
        fields.extend([0xAA, 0xBB]); // mask 0x0001: 2 bytes
    }
    fields.extend([0, 0, 0, 0, result, running, 0]); // mask 0x0100: 7 bytes on 0x14
    let mut body = ByteBuffer::new();
    body.write_u32(8 + 8 + fields.len() as u32); // blob length = record size - 8
    body.write_u16(mask);
    body.write_u16(0);
    body.write_bytes(&fields);
    record(event::OLC_INFO_CHANGED, body.bytes())
}

/// What the scripted camera reports once AF has been started.
struct AfScript {
    started: bool,
    reports: Vec<Vec<u8>>,
}

fn touch_rig_handler(rig: &Rig, focus_mode: u32, reports: Vec<Vec<u8>>) -> CanonHandler {
    rig.transport.ok_all();
    let script = Arc::new(Mutex::new(AfScript {
        started: false,
        reports,
    }));
    let s1 = script.clone();
    rig.transport.on(op::DO_AF, move |_| {
        s1.lock().unwrap().started = true;
        ok(vec![])
    });
    rig.transport.on(op::GET_EVENT, move |_| {
        let mut s = script.lock().unwrap();
        let mut out = if s.started && !s.reports.is_empty() {
            s.reports.remove(0)
        } else {
            Vec::new()
        };
        out.extend(TERMINATOR);
        ok(out)
    });
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    let mut dump = prop_value_changed(prop::OLC_INFO_VERSION, 0x14);
    dump.extend(prop_value_changed(prop::FOCUS_MODE, focus_mode));
    dump.extend(TERMINATOR);
    h.ingest(&dump);
    h
}

fn focus_mode_writes(rig: &Rig) -> Vec<Vec<u8>> {
    let a = CanonHandler::set_property_payload(prop::FOCUS_MODE, 0);
    let b = CanonHandler::set_property_payload(prop::FOCUS_MODE, 1);
    rig.transport
        .requests_for(op::SET_DEVICE_PROP_VALUE_EX)
        .into_iter()
        .filter_map(|r| r.data_out)
        .filter(|d| *d == a || *d == b)
        .collect()
}

#[test]
fn olc_focus_info_parses_the_r5_mark_ii_states() {
    let state = |bytes: Vec<u8>| {
        let mut d = bytes;
        d.extend(TERMINATOR);
        CanonHandler::olc_focus_state(&CanonEventRecord::parse(&d)[0], 0x14)
    };
    assert_eq!(state(olc_focus(0, 1, false)), Some(AfState::Running));
    assert_eq!(state(olc_focus(1, 1, false)), Some(AfState::Focused));
    assert_eq!(state(olc_focus(2, 1, false)), Some(AfState::Failed));
    assert_eq!(state(olc_focus(0, 0, false)), Some(AfState::Idle));
    assert_eq!(
        state(olc_focus(1, 1, true)),
        Some(AfState::Focused),
        "earlier fields shift the offset"
    );
    let mut d = olc_focus(1, 1, false);
    d.extend(TERMINATOR);
    assert_eq!(
        CanonHandler::olc_focus_state(&CanonEventRecord::parse(&d)[0], 0),
        None
    );
    // Versions past the table use its last row.
    assert_eq!(
        CanonHandler::olc_focus_state(&CanonEventRecord::parse(&d)[0], 0x30),
        Some(AfState::Focused)
    );
}

#[tokio::test]
async fn tap_stops_on_the_cameras_own_lock_report() {
    // R8 / R5 Mark II success: 00-01 → 01-01 → 00-00, the last two in one dump.
    let rig = Rig::new(canon_r5_mark_ii()).await;
    let mut second = olc_focus(1, 1, false);
    second.extend(olc_focus(0, 0, false));
    let h = touch_rig_handler(
        &rig,
        canon::FOCUS_MODE_ONE_SHOT,
        vec![olc_focus(0, 1, false), second],
    );
    let started = Instant::now();
    let result = h.focus(0.5, 0.5).await.unwrap();
    assert_eq!(result, FocusResult::Focused);
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "returns on the report, not a timer"
    );
    assert!(!rig.codes().contains(&op::AF_CANCEL));
    assert!(focus_mode_writes(&rig).is_empty());
    // The AF point lands in the fallback space (8192 x 5464) at the centre.
    assert_eq!(
        rig.transport.requests_for(op::TOUCH_AF_POSITION)[0].parameters,
        vec![canon::TOUCH_AF_TYPE, 4095, 2731]
    );
}

#[tokio::test]
async fn failed_af_is_reported() {
    // R5 Mark II failure trace: 00-01, 02-01, 02-00, 00-00.
    let rig = Rig::new(canon_r5_mark_ii()).await;
    let h = touch_rig_handler(
        &rig,
        canon::FOCUS_MODE_ONE_SHOT,
        vec![
            olc_focus(0, 1, false),
            olc_focus(2, 1, false),
            olc_focus(2, 0, false),
            olc_focus(0, 0, false),
        ],
    );
    assert_eq!(h.focus(0.2, 0.8).await.unwrap(), FocusResult::Failed);
}

#[tokio::test]
async fn servo_tap_locks_in_one_shot_then_restores_servo_right_away() {
    let rig = Rig::new(canon_r5_mark_ii()).await;
    let h = touch_rig_handler(
        &rig,
        canon::FOCUS_MODE_SERVO,
        vec![olc_focus(0, 1, false), olc_focus(1, 1, false)],
    );
    assert_eq!(h.focus(0.5, 0.5).await.unwrap(), FocusResult::Focused);
    assert_eq!(
        focus_mode_writes(&rig),
        vec![
            CanonHandler::set_property_payload(prop::FOCUS_MODE, 0),
            CanonHandler::set_property_payload(prop::FOCUS_MODE, 1)
        ]
    );
    let codes = rig.codes();
    let one_shot = codes
        .iter()
        .position(|c| *c == op::SET_DEVICE_PROP_VALUE_EX)
        .unwrap();
    let restore = codes
        .iter()
        .rposition(|c| *c == op::SET_DEVICE_PROP_VALUE_EX)
        .unwrap();
    let do_af = codes.iter().position(|c| *c == op::DO_AF).unwrap();
    assert!(one_shot < do_af);
    assert!(restore > do_af);
    assert!(!codes.contains(&op::AF_CANCEL), "One Shot stops itself");
    assert_eq!(h.value(prop::FOCUS_MODE), Some(canon::FOCUS_MODE_SERVO));
}

#[tokio::test]
async fn servo_tap_that_cannot_switch_mode_is_cancelled_after_the_report() {
    let rig = Rig::new(canon_r5_mark_ii()).await;
    let h = touch_rig_handler(&rig, canon::FOCUS_MODE_SERVO, vec![olc_focus(1, 1, false)]);
    // The body refuses the switch to One Shot (mode locked).
    rig.transport.on(op::SET_DEVICE_PROP_VALUE_EX, |_| {
        fail(ResponseCode::ACCESS_DENIED)
    });
    assert_eq!(h.focus(0.5, 0.5).await.unwrap(), FocusResult::Focused);
    assert_eq!(rig.codes().last(), Some(&op::AF_CANCEL));
}

#[tokio::test]
async fn hold_tracks_in_the_users_mode_until_released() {
    let rig = Rig::new(canon_r5_mark_ii()).await;
    let h = touch_rig_handler(&rig, canon::FOCUS_MODE_SERVO, vec![]);
    h.start_tracking_focus(0.4, 0.4).await.unwrap();
    assert!(rig.codes().contains(&op::DO_AF));
    assert!(!rig.codes().contains(&op::AF_CANCEL));
    assert!(focus_mode_writes(&rig).is_empty(), "tracking keeps Servo");
    h.stop_tracking_focus().await;
    assert_eq!(rig.codes().last(), Some(&op::AF_CANCEL));
    // A second stop is a no-op.
    let n = rig.codes().len();
    h.stop_tracking_focus().await;
    assert_eq!(rig.codes().len(), n);
}

#[tokio::test]
async fn touch_focus_needs_the_touch_af_operation() {
    let rig = Rig::new(canon()).await;
    let h = CanonHandler::new(rig.engine.clone(), rig.info.clone());
    assert!(matches!(
        h.focus(0.5, 0.5).await,
        Err(PtpError::Unsupported(_))
    ));
    assert!(matches!(
        h.start_tracking_focus(0.5, 0.5).await,
        Err(PtpError::Unsupported(_))
    ));
}
