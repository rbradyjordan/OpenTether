//! Port of `NikonVendorTests.swift`.

mod common;

use common::*;
use tether_ptp::device::{CameraEvent, NewObject, TetherProperty, VendorHandler};
use tether_ptp::ptp::*;
use tether_ptp::testing::{fail, fake_jpeg, ok};
use tether_ptp::vendors::nikon::{self, op, NikonHandler};
use tether_types::{CameraCapabilities as C, CameraVendor, CaptureDestination, LiveViewQuality};

fn events(pairs: &[(u16, u32)]) -> Vec<u8> {
    let mut b = ByteBuffer::new();
    b.write_u16(pairs.len() as u16);
    for (c, p) in pairs {
        b.write_u16(*c);
        b.write_u32(*p);
    }
    b.into_bytes()
}

fn handler(rig: &Rig) -> NikonHandler {
    NikonHandler::new(rig.engine.clone(), rig.info.clone())
}

#[test]
fn capabilities_derive_from_operations() {
    let h = NikonHandler::new(idle_engine(&nikon_z()), nikon_z());
    assert_eq!(h.vendor(), CameraVendor::Nikon);
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
    assert_eq!(
        h.destination(),
        CaptureDestination::Host,
        "SDRAM bodies default to host"
    );
    let plain_info = info("Nikon", "Coolpix", &[0x100E]);
    let plain = NikonHandler::new(idle_engine(&plain_info), plain_info);
    assert!(plain.capabilities().contains(C::CARD_CAPTURE));
    assert!(!plain.capabilities().contains(C::SDRAM_CAPTURE));
    assert!(!plain.capabilities().contains(C::LIVE_VIEW));
    assert_eq!(plain.destination(), CaptureDestination::Card);
}

#[tokio::test]
async fn prepare_switches_application_mode_then_waits_for_device_ready() {
    let rig = Rig::new(nikon_z()).await;
    rig.transport.ok_all();
    handler(&rig).prepare().await.unwrap();
    assert_eq!(
        rig.codes(),
        vec![op::CHANGE_APPLICATION_MODE, op::DEVICE_READY]
    );
    assert_eq!(rig.params()[0], vec![1]);
    // A DSLR advertising ChangeCameraMode uses that instead.
    let rig2 = Rig::new(nikon_d()).await;
    rig2.transport.ok_all();
    handler(&rig2).prepare().await.unwrap();
    assert_eq!(rig2.codes()[0], op::CHANGE_CAMERA_MODE);
    handler(&rig2).teardown().await;
    assert_eq!(rig2.codes().last(), Some(&op::CHANGE_CAMERA_MODE));
    assert_eq!(rig2.params().last().unwrap(), &vec![0]);
}

#[tokio::test]
async fn device_ready_retries_busy_then_gives_up() {
    let rig = Rig::new(nikon_z()).await;
    rig.transport.ok_all();
    let n = std::sync::Arc::new(Counter::default());
    let n2 = n.clone();
    rig.transport.on(op::DEVICE_READY, move |_| {
        if n2.increment() < 3 {
            fail(ResponseCode::DEVICE_BUSY)
        } else {
            ok(vec![])
        }
    });
    let h = handler(&rig);
    h.wait_until_ready().await.unwrap();
    assert_eq!(n.value(), 3);
    rig.transport
        .on(op::DEVICE_READY, |_| fail(ResponseCode::DEVICE_BUSY));
    h.set_ready_attempts(2);
    let e = h.wait_until_ready().await.unwrap_err();
    assert_eq!(e.response_code(), Some(ResponseCode::DEVICE_BUSY));
    // Anything other than busy fails at once.
    rig.transport
        .on(op::DEVICE_READY, |_| fail(ResponseCode::GENERAL_ERROR));
    let before = rig.transport.requests_for(op::DEVICE_READY).len();
    assert!(h.wait_until_ready().await.is_err());
    assert_eq!(
        rig.transport.requests_for(op::DEVICE_READY).len(),
        before + 1
    );
}

#[tokio::test]
async fn capture_to_sdram_and_to_card() {
    let rig = Rig::new(nikon_z()).await;
    rig.transport.ok_all();
    let h = handler(&rig);
    h.set_capture_destination(CaptureDestination::Host)
        .await
        .unwrap();
    h.capture(true).await.unwrap();
    assert_eq!(rig.codes(), vec![op::AF_CAPTURE_SDRAM, op::DEVICE_READY]);
    let rig2 = Rig::new(nikon_z()).await;
    rig2.transport.ok_all();
    let h2 = handler(&rig2);
    h2.set_capture_destination(CaptureDestination::Host)
        .await
        .unwrap();
    h2.capture(false).await.unwrap();
    assert_eq!(rig2.codes()[0], op::INITIATE_CAPTURE_REC_IN_SDRAM);
    assert_eq!(rig2.params()[0], vec![0xFFFF_FFFF]);
    let rig3 = Rig::new(nikon_z()).await;
    rig3.transport.ok_all();
    let h3 = handler(&rig3);
    h3.set_capture_destination(CaptureDestination::Both)
        .await
        .unwrap();
    h3.capture(false).await.unwrap();
    assert_eq!(rig3.codes()[0], op::INITIATE_CAPTURE_REC_IN_MEDIA);
    assert_eq!(rig3.params()[0], vec![0xFFFF_FFFF, 1]);
    h3.set_capture_destination(CaptureDestination::Card)
        .await
        .unwrap();
    h3.capture(true).await.unwrap();
    assert_eq!(rig3.params()[2], vec![0, 0]);
}

#[tokio::test]
async fn destination_rules_follow_the_body() {
    let coolpix = info("Nikon", "Coolpix", &[0x100E]);
    let rig = Rig::new(coolpix).await;
    rig.transport.ok_all();
    let h = handler(&rig);
    assert!(h
        .set_capture_destination(CaptureDestination::Host)
        .await
        .is_err());
    assert!(h
        .set_capture_destination(CaptureDestination::Both)
        .await
        .is_err());
    h.capture(true).await.unwrap();
    assert_eq!(rig.codes(), vec![OperationCode::INITIATE_CAPTURE]);
    let props = h
        .read_properties(&[TetherProperty::CaptureDestination])
        .await
        .unwrap();
    assert!(!props[0].is_writable, "one choice only");
}

#[tokio::test]
async fn get_event_pairs_become_camera_events() {
    let rig = Rig::new(nikon_z()).await;
    rig.transport.on(op::GET_EVENT, |_| {
        ok(events(&[
            (0xC101, 0xFFFF_0001),
            (0x4006, 0x5007),
            (0xC102, 0),
            (0x4002, 0x0000_1234),
            (0x4006, 0xD100),
            (0xC104, 0),
            (0xC105, 0),
        ]))
    });
    let h = handler(&rig);
    let ev = h.poll_events().await.unwrap();
    assert_eq!(
        ev,
        vec![
            CameraEvent::ObjectAdded(NewObject {
                in_sdram: true,
                ..NewObject::new(0xFFFF_0001)
            }),
            CameraEvent::PropertyChanged(Some(TetherProperty::Aperture)),
            CameraEvent::CaptureComplete,
            CameraEvent::ObjectAdded(NewObject::new(0x1234)),
            CameraEvent::PropertyChanged(Some(TetherProperty::ShutterSpeed)),
            CameraEvent::Warning("Movie recording was interrupted.".into()),
        ]
    );
    assert!(NikonHandler::parse_events(&[]).unwrap().is_empty());
    // Handle 0 in SDRAM means the fixed SDRAM handle.
    let zero = h
        .translate(&PtpEvent::new(nikon::event::OBJECT_ADDED_IN_SDRAM, [0]))
        .await;
    assert_eq!(
        zero,
        Some(CameraEvent::ObjectAdded(NewObject {
            in_sdram: true,
            ..NewObject::new(nikon::SDRAM_HANDLE)
        }))
    );
}

#[tokio::test]
async fn property_read_display_and_write() {
    let rig = Rig::new(nikon_z()).await;
    rig.transport.on(
        OperationCode::GET_DEVICE_PROP_DESC,
        |req| match DevicePropCode(req.parameters[0] as u16) {
            DevicePropCode::F_NUMBER => ok(prop_desc(
                DevicePropCode::F_NUMBER,
                DataType::UINT16,
                280,
                &[280, 400, 560],
                true,
            )),
            nikon::prop::SHUTTER_SPEED => ok(prop_desc(
                nikon::prop::SHUTTER_SPEED,
                DataType::UINT32,
                1 << 16 | 250,
                &[1 << 16 | 125, 1 << 16 | 250, 20 << 16 | 10, 0xFFFF_FFFF],
                true,
            )),
            DevicePropCode::EXPOSURE_INDEX => ok(prop_desc(
                DevicePropCode::EXPOSURE_INDEX,
                DataType::UINT16,
                400,
                &[100, 400, 0xFFFF],
                true,
            )),
            DevicePropCode::WHITE_BALANCE => ok(prop_desc(
                DevicePropCode::WHITE_BALANCE,
                DataType::UINT16,
                0x8010,
                &[2, 4, 0x8010],
                true,
            )),
            DevicePropCode::BATTERY_LEVEL => ok(prop_desc(
                DevicePropCode::BATTERY_LEVEL,
                DataType::UINT8,
                80,
                &[],
                false,
            )),
            _ => fail(ResponseCode::DEVICE_PROP_NOT_SUPPORTED),
        },
    );
    rig.transport
        .on(OperationCode::SET_DEVICE_PROP_VALUE, |_| ok(vec![]));
    let h = handler(&rig);
    let props = h
        .read_properties(&[
            TetherProperty::Aperture,
            TetherProperty::ShutterSpeed,
            TetherProperty::Iso,
            TetherProperty::WhiteBalance,
            TetherProperty::BatteryLevel,
            TetherProperty::CaptureDestination,
        ])
        .await
        .unwrap();
    let by = |p: TetherProperty| props.iter().find(|d| d.property == p).unwrap().clone();
    assert_eq!(by(TetherProperty::Aperture).display, "ƒ/2.8");
    assert_eq!(by(TetherProperty::ShutterSpeed).display, "1/250");
    let shutters: Vec<String> = by(TetherProperty::ShutterSpeed)
        .choices()
        .iter()
        .map(|c| c.display.clone())
        .collect();
    assert_eq!(shutters, ["1/125", "1/250", "2\"", "Bulb"]);
    assert_eq!(by(TetherProperty::Iso).display, "400");
    assert_eq!(
        by(TetherProperty::Iso).choices().last().unwrap().display,
        "Auto"
    );
    assert_eq!(by(TetherProperty::WhiteBalance).display, "Cloudy");
    assert_eq!(by(TetherProperty::BatteryLevel).display, "80%");
    assert_eq!(by(TetherProperty::CaptureDestination).choices().len(), 3);
    h.write_property(
        TetherProperty::ShutterSpeed,
        by(TetherProperty::ShutterSpeed).choices()[0].raw.clone(),
    )
    .await
    .unwrap();
    let set = rig
        .transport
        .requests_for(OperationCode::SET_DEVICE_PROP_VALUE)
        .pop()
        .unwrap();
    assert_eq!(set.parameters, vec![0xD100]);
    assert_eq!(
        set.data_out,
        Some(PtpValue::UInt32(1 << 16 | 125).encoded())
    );
    // Destination written through the descriptor's raw value.
    let host = by(TetherProperty::CaptureDestination)
        .choices()
        .iter()
        .find(|c| c.display == CaptureDestination::Host.display_name())
        .unwrap()
        .raw
        .clone();
    h.write_property(TetherProperty::CaptureDestination, host)
        .await
        .unwrap();
    let after = h
        .read_properties(&[TetherProperty::CaptureDestination])
        .await
        .unwrap();
    assert_eq!(after[0].display, CaptureDestination::Host.display_name());
    assert!(h
        .write_property(TetherProperty::CaptureDestination, PtpValue::UInt8(9))
        .await
        .is_err());
    assert!(h
        .write_property(TetherProperty::PictureStyle, PtpValue::UInt8(1))
        .await
        .is_err());
}

#[tokio::test]
async fn live_view_refused_when_prohibit_condition_set() {
    let rig = Rig::new(nikon_z()).await;
    rig.transport.ok_all();
    rig.transport.on(OperationCode::GET_DEVICE_PROP_VALUE, |_| {
        ok(PtpValue::UInt32(1 | 1 << 16).encoded())
    });
    let h = handler(&rig);
    match h.start_live_view(LiveViewQuality::Medium).await {
        Err(PtpError::VendorGate(msg)) => {
            assert!(msg.contains("card"));
            assert!(msg.contains("temperature"));
        }
        other => panic!("{other:?}"),
    }
    assert!(!rig.codes().contains(&op::START_LIVE_VIEW));
}

#[tokio::test]
async fn live_view_starts_and_finds_jpeg_behind_header() {
    let rig = Rig::new(nikon_z()).await;
    rig.transport.ok_all();
    rig.transport.on(OperationCode::GET_DEVICE_PROP_VALUE, |_| {
        ok(PtpValue::UInt32(0).encoded())
    });
    let jpeg = fake_jpeg(300);
    let mut payload = vec![0u8; 384];
    payload.extend(&jpeg);
    rig.transport
        .on(op::GET_LIVE_VIEW_IMG, move |_| ok(payload.clone()));
    let h = handler(&rig);
    h.start_live_view(LiveViewQuality::High).await.unwrap();
    assert!(rig.codes().contains(&op::START_LIVE_VIEW));
    let f = h.next_live_view_frame().await.unwrap().unwrap();
    assert_eq!(f.jpeg, jpeg);
    assert_eq!(f.sequence, 1);
    rig.transport
        .on(op::GET_LIVE_VIEW_IMG, |_| fail(ResponseCode::DEVICE_BUSY));
    assert!(h.next_live_view_frame().await.unwrap().is_none());
    h.stop_live_view().await;
    assert_eq!(rig.codes().last(), Some(&op::END_LIVE_VIEW));
    assert!(h.next_live_view_frame().await.unwrap().is_none());
}

#[tokio::test]
async fn sdram_fetch_uses_get_object_info_and_get_object() {
    let rig = Rig::new(nikon_z()).await;
    let payload = fake_jpeg(500);
    let p2 = payload.clone();
    rig.transport.on(OperationCode::GET_OBJECT_INFO, |_| {
        ok(PtpObjectInfo {
            object_compressed_size: 500,
            filename: "DSC_0001.JPG".into(),
            ..Default::default()
        }
        .encoded())
    });
    rig.transport
        .on(OperationCode::GET_OBJECT, move |_| ok(p2.clone()));
    let h = handler(&rig);
    let (oi, data) = h
        .fetch_object(
            &NewObject {
                in_sdram: true,
                ..NewObject::new(nikon::SDRAM_HANDLE)
            },
            None,
        )
        .await
        .unwrap();
    assert_eq!(oi.filename, "DSC_0001.JPG");
    assert_eq!(data, payload);
    assert_eq!(
        rig.codes(),
        vec![OperationCode::GET_OBJECT_INFO, OperationCode::GET_OBJECT]
    );
}
