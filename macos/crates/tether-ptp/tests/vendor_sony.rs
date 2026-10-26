//! Port of `SonyVendorTests.swift`.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use tether_ptp::device::{CameraEvent, NewObject, PropertyForm, TetherProperty, VendorHandler};
use tether_ptp::ptp::*;
use tether_ptp::testing::{fail, fake_jpeg, ok};
use tether_ptp::vendors::sony::{self, op, prop, SonyHandler, SonyPropDesc};
use tether_types::{CameraCapabilities as C, CameraVendor, CaptureDestination, LiveViewQuality};

fn desc(
    code: DevicePropCode,
    t: DataType,
    writable: bool,
    current: PtpValue,
    form: PropForm,
    settable: Option<Vec<PtpValue>>,
) -> SonyPropDesc {
    SonyPropDesc {
        settable,
        ..SonyPropDesc::new(code, t, writable, current, form)
    }
}

fn dump(focus: u8, object_in_memory: u16, two_lists: bool) -> Vec<u8> {
    use PtpValue::*;
    let s = |v: Vec<PtpValue>| if two_lists { Some(v) } else { None };
    let mut iso = desc(
        prop::ISO,
        DataType::UINT32,
        true,
        UInt32(prop::ISO_AUTO),
        PropForm::Enumeration(vec![UInt32(prop::ISO_AUTO), UInt32(100), UInt32(6400)]),
        s(vec![]),
    );
    iso.is_enabled = false;
    SonyPropDesc::encode_all(&[
        desc(
            DevicePropCode::F_NUMBER,
            DataType::UINT16,
            true,
            UInt16(280),
            PropForm::Enumeration(vec![UInt16(280), UInt16(400)]),
            s(vec![UInt16(280), UInt16(400)]),
        ),
        desc(
            prop::SHUTTER_SPEED,
            DataType::UINT32,
            true,
            UInt32(1 << 16 | 250),
            PropForm::Enumeration(vec![
                UInt32(1 << 16 | 125),
                UInt32(1 << 16 | 250),
                UInt32(1 << 16 | 500),
            ]),
            s(vec![UInt32(1 << 16 | 125), UInt32(1 << 16 | 250)]),
        ),
        iso,
        desc(
            DevicePropCode::EXPOSURE_BIAS_COMPENSATION,
            DataType::INT16,
            true,
            Int16(-700),
            PropForm::Range {
                min: Int16(-5000),
                max: Int16(5000),
                step: Int16(300),
            },
            None,
        ),
        desc(
            DevicePropCode::WHITE_BALANCE,
            DataType::UINT16,
            true,
            UInt16(0x8011),
            PropForm::Enumeration(vec![UInt16(2), UInt16(4), UInt16(0x8011)]),
            s(vec![UInt16(2), UInt16(4), UInt16(0x8011)]),
        ),
        desc(
            prop::BATTERY_LEVEL,
            DataType::UINT8,
            false,
            UInt8(65),
            PropForm::None,
            None,
        ),
        desc(
            prop::FOCUS_FOUND,
            DataType::UINT8,
            false,
            UInt8(focus),
            PropForm::None,
            None,
        ),
        desc(
            prop::OBJECT_IN_MEMORY,
            DataType::UINT16,
            false,
            UInt16(object_in_memory),
            PropForm::None,
            None,
        ),
    ])
}

fn handler(rig: &Rig) -> SonyHandler {
    SonyHandler::new(rig.engine.clone(), rig.info.clone())
}

#[test]
fn capabilities_derive_from_sdio_operations() {
    let h = SonyHandler::new(idle_engine(&sony()), sony());
    assert_eq!(h.vendor(), CameraVendor::Sony);
    for c in [
        C::REMOTE_CAPTURE,
        C::SDRAM_CAPTURE,
        C::CARD_CAPTURE,
        C::LIVE_VIEW,
        C::PROPERTY_CONTROL,
        C::AUTOFOCUS,
        C::PARTIAL_TRANSFER,
        C::THUMBNAILS,
    ] {
        assert!(h.capabilities().contains(c), "{c:?}");
    }
    let ms = SonyHandler::new(idle_engine(&sony_mass_storage()), sony_mass_storage());
    assert!(!ms.capabilities().contains(C::REMOTE_CAPTURE));
    assert!(!ms.capabilities().contains(C::PROPERTY_CONTROL));
}

#[tokio::test]
async fn prepare_runs_sdio_connect_sequence() {
    let rig = Rig::new(sony()).await;
    rig.transport.ok_all();
    rig.transport
        .on(op::SDIO_GET_ALL_EXT_DEVICE_PROP_INFO, |_| {
            ok(dump(3, 0, true))
        });
    let h = handler(&rig);
    h.prepare().await.unwrap();
    assert_eq!(
        rig.codes(),
        vec![
            op::SDIO_CONNECT,
            op::SDIO_CONNECT,
            op::SDIO_GET_EXT_DEVICE_INFO,
            op::SDIO_CONNECT,
            op::SDIO_GET_ALL_EXT_DEVICE_PROP_INFO
        ]
    );
    assert_eq!(
        rig.params()[..4],
        [vec![1, 0, 0], vec![2, 0, 0], vec![0x12C], vec![3, 0, 0]]
    );
    assert_eq!(h.props().len(), 8);
}

#[tokio::test]
async fn prepare_retries_ext_device_info_with_fallback_version() {
    let rig = Rig::new(sony()).await;
    rig.transport.ok_all();
    rig.transport.on(op::SDIO_GET_EXT_DEVICE_INFO, |r| {
        if r.parameters == [0x12C] {
            fail(ResponseCode::INVALID_PARAMETER)
        } else {
            ok(vec![])
        }
    });
    rig.transport
        .on(op::SDIO_GET_ALL_EXT_DEVICE_PROP_INFO, |_| {
            ok(dump(3, 0, true))
        });
    handler(&rig).prepare().await.unwrap();
    let p: Vec<Vec<u32>> = rig
        .transport
        .requests_for(op::SDIO_GET_EXT_DEVICE_INFO)
        .into_iter()
        .map(|r| r.parameters)
        .collect();
    assert_eq!(p, vec![vec![0x12C], vec![0xC8]]);
}

#[tokio::test]
async fn prepare_without_sdio_throws_gate_message() {
    let rig = Rig::new(sony_mass_storage()).await;
    match handler(&rig).prepare().await {
        Err(PtpError::VendorGate(m)) => assert!(m.contains("PC Remote")),
        other => panic!("{other:?}"),
    }
}

#[tokio::test]
async fn capture_half_press_waits_for_focus_then_full_press_and_release() {
    let rig = Rig::new(sony()).await;
    rig.transport.ok_all();
    rig.transport
        .on(op::SDIO_GET_ALL_EXT_DEVICE_PROP_INFO, |_| {
            ok(dump(3, 0, true))
        });
    handler(&rig).capture(true).await.unwrap();
    let controls = rig.transport.requests_for(op::SDIO_CONTROL_DEVICE);
    let params: Vec<Vec<u32>> = controls.iter().map(|r| r.parameters.clone()).collect();
    assert_eq!(
        params,
        vec![vec![0xD2C1], vec![0xD2C2], vec![0xD2C2], vec![0xD2C1]]
    );
    let data: Vec<Vec<u8>> = controls
        .iter()
        .map(|r| r.data_out.clone().unwrap())
        .collect();
    assert_eq!(data, vec![vec![2, 0], vec![2, 0], vec![1, 0], vec![1, 0]]);
    assert_eq!(rig.codes()[1], op::SDIO_GET_ALL_EXT_DEVICE_PROP_INFO); // the focus poll
    let rig2 = Rig::new(sony()).await;
    rig2.transport.ok_all();
    handler(&rig2).capture(false).await.unwrap();
    assert_eq!(rig2.params(), vec![vec![0xD2C2], vec![0xD2C2]]);
}

#[tokio::test]
async fn capture_gives_up_waiting_for_focus_after_timeout() {
    let rig = Rig::new(sony()).await;
    rig.transport.ok_all();
    rig.transport
        .on(op::SDIO_GET_ALL_EXT_DEVICE_PROP_INFO, |_| {
            ok(dump(1, 0, true))
        });
    let h = handler(&rig);
    h.set_focus_timeout(Duration::from_millis(150));
    h.set_focus_poll_interval(Duration::from_millis(50));
    h.capture(true).await.unwrap();
    assert!(
        rig.transport
            .requests_for(op::SDIO_GET_ALL_EXT_DEVICE_PROP_INFO)
            .len()
            >= 2
    );
    assert_eq!(rig.transport.requests_for(op::SDIO_CONTROL_DEVICE).len(), 4);
}

#[tokio::test]
async fn capture_without_sdio_uses_initiate_capture_or_refuses() {
    let mut plain = sony_mass_storage();
    plain
        .operations_supported
        .push(OperationCode::INITIATE_CAPTURE);
    let rig = Rig::new(plain).await;
    rig.transport.ok_all();
    let h = handler(&rig);
    assert!(h.capabilities().contains(C::REMOTE_CAPTURE));
    h.capture(true).await.unwrap();
    assert_eq!(rig.codes(), vec![OperationCode::INITIATE_CAPTURE]);
    let rig2 = Rig::new(sony_mass_storage()).await;
    assert!(matches!(
        handler(&rig2).capture(true).await,
        Err(PtpError::Unsupported(_))
    ));
}

#[tokio::test]
async fn object_in_memory_poll_emits_sdram_object() {
    let rig = Rig::new(sony()).await;
    let counter = Arc::new(Counter::default());
    let c2 = counter.clone();
    rig.transport
        .on(op::SDIO_GET_ALL_EXT_DEVICE_PROP_INFO, move |_| {
            let n = c2.increment();
            ok(dump(3, if n == 1 { 0 } else { 0x8001 }, true))
        });
    let h = handler(&rig);
    let sdram = CameraEvent::ObjectAdded(NewObject {
        in_sdram: true,
        ..NewObject::new(sony::SDRAM_HANDLE)
    });
    let first = h.poll_events().await.unwrap();
    assert!(!first.contains(&sdram));
    // Everything is new on the first poll (no previous dump).
    assert!(first.contains(&CameraEvent::PropertyChanged(Some(
        TetherProperty::ShutterSpeed
    ))));
    let second = h.poll_events().await.unwrap();
    assert!(second.contains(&sdram));
    assert!(
        !second.contains(&CameraEvent::PropertyChanged(Some(
            TetherProperty::ShutterSpeed
        ))),
        "unchanged values are not re-announced"
    );
    let pushed = h
        .translate(&PtpEvent::new(
            sony::event::OBJECT_ADDED,
            [sony::SDRAM_HANDLE],
        ))
        .await;
    assert_eq!(pushed, Some(sdram.clone()));
    let zero = h
        .translate(&PtpEvent::new(sony::event::OBJECT_ADDED, [0]))
        .await;
    assert_eq!(zero, Some(sdram));
    let card = h
        .translate(&PtpEvent::new(sony::event::OBJECT_ADDED, [0x10]))
        .await;
    assert_eq!(card, Some(CameraEvent::ObjectAdded(NewObject::new(0x10))));
    let p = h
        .translate(&PtpEvent::new(sony::event::PROPERTY_CHANGED, [0xD20D]))
        .await;
    assert_eq!(
        p,
        Some(CameraEvent::PropertyChanged(Some(
            TetherProperty::ShutterSpeed
        )))
    );
    let removed = h
        .translate(&PtpEvent::new(sony::event::OBJECT_REMOVED, [7]))
        .await;
    assert_eq!(removed, Some(CameraEvent::ObjectRemoved { handle: 7 }));
}

#[test]
fn sdio_all_props_parse_both_layouts() {
    let two = SonyPropDesc::parse_all(&dump(3, 0, true)).unwrap();
    assert_eq!(two.len(), 8);
    let shutter = two.iter().find(|d| d.code == prop::SHUTTER_SPEED).unwrap();
    assert!(matches!(&shutter.form, PropForm::Enumeration(v) if v.len() == 3));
    assert_eq!(shutter.settable.as_ref().unwrap().len(), 2);
    assert_eq!(shutter.choices().unwrap().len(), 2); // the set-able list wins
    let iso = two.iter().find(|d| d.code == prop::ISO).unwrap();
    assert!(!iso.is_enabled);
    assert_eq!(iso.choices().unwrap().len(), 3); // empty second list falls back to the first
    let one = SonyPropDesc::parse_all(&dump(3, 0, false)).unwrap();
    assert_eq!(one.len(), 8);
    assert!(one
        .iter()
        .find(|d| d.code == prop::SHUTTER_SPEED)
        .unwrap()
        .settable
        .is_none());
    assert_eq!(
        one.iter()
            .find(|d| d.code == prop::BATTERY_LEVEL)
            .unwrap()
            .current,
        PtpValue::UInt8(65)
    );
    assert!(SonyPropDesc::parse_all(&[1, 0, 0, 0, 0, 0, 0, 0, 0xFF]).is_err());
}

#[tokio::test]
async fn property_read_display_and_write() {
    let rig = Rig::new(sony()).await;
    rig.transport.ok_all();
    rig.transport
        .on(op::SDIO_GET_ALL_EXT_DEVICE_PROP_INFO, |_| {
            ok(dump(3, 0, true))
        });
    let h = handler(&rig);
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
    let by = |p: TetherProperty| props.iter().find(|d| d.property == p).unwrap().clone();
    let shows = |p: TetherProperty| -> Vec<String> {
        by(p).choices().iter().map(|c| c.display.clone()).collect()
    };
    assert_eq!(by(TetherProperty::Aperture).display, "ƒ/2.8");
    assert_eq!(by(TetherProperty::ShutterSpeed).display, "1/250");
    assert_eq!(shows(TetherProperty::ShutterSpeed), ["1/125", "1/250"]);
    assert_eq!(by(TetherProperty::Iso).display, "Auto");
    assert!(!by(TetherProperty::Iso).is_writable); // is_enabled = false
    assert_eq!(by(TetherProperty::ExposureCompensation).display, "-0.7");
    assert_eq!(
        by(TetherProperty::ExposureCompensation).form,
        PropertyForm::Range {
            min: -5000.0,
            max: 5000.0,
            step: 300.0
        }
    );
    assert_eq!(by(TetherProperty::WhiteBalance).display, "Shade");
    assert_eq!(by(TetherProperty::BatteryLevel).display, "65%");
    assert!(!by(TetherProperty::BatteryLevel).is_writable);
    assert_eq!(
        shows(TetherProperty::CaptureDestination),
        [
            CaptureDestination::Card.display_name(),
            CaptureDestination::Both.display_name()
        ]
    );
    h.write_property(
        TetherProperty::ShutterSpeed,
        by(TetherProperty::ShutterSpeed).choices()[0].raw.clone(),
    )
    .await
    .unwrap();
    let set = rig
        .transport
        .requests_for(op::SDIO_SET_EXT_DEVICE_PROP_VALUE)
        .pop()
        .unwrap();
    assert_eq!(set.parameters, vec![0xD20D]);
    assert_eq!(
        set.data_out,
        Some(PtpValue::UInt32(1 << 16 | 125).encoded())
    );
    match h.set_capture_destination(CaptureDestination::Host).await {
        Err(PtpError::Unsupported(m)) => assert!(m.contains("Save Dest")),
        other => panic!("{other:?}"),
    }
    // Card is fine, through the property too.
    h.write_property(TetherProperty::CaptureDestination, PtpValue::UInt8(0))
        .await
        .unwrap();
    let d = h
        .read_properties(&[TetherProperty::CaptureDestination])
        .await
        .unwrap();
    assert_eq!(d[0].display, CaptureDestination::Card.display_name());
}

#[tokio::test]
async fn live_view_frame_comes_from_fixed_handle() {
    let rig = Rig::new(sony()).await;
    let jpeg = fake_jpeg(128);
    let mut payload = vec![0u8; 8];
    payload.extend(&jpeg);
    rig.transport.on(OperationCode::GET_OBJECT_INFO, |_| {
        ok(PtpObjectInfo {
            object_compressed_size: 128,
            ..Default::default()
        }
        .encoded())
    });
    rig.transport
        .on(OperationCode::GET_OBJECT, move |_| ok(payload.clone()));
    let h = handler(&rig);
    h.start_live_view(LiveViewQuality::Low).await.unwrap();
    let f = h.next_live_view_frame().await.unwrap().unwrap();
    assert_eq!(f.jpeg, jpeg);
    assert_eq!(
        rig.params(),
        vec![vec![sony::LIVE_VIEW_HANDLE], vec![sony::LIVE_VIEW_HANDLE]]
    );
    // Not streaming yet: no frame, no error.
    rig.transport.on(OperationCode::GET_OBJECT_INFO, |_| {
        fail(ResponseCode::INVALID_OBJECT_HANDLE)
    });
    assert!(h.next_live_view_frame().await.unwrap().is_none());
}

#[tokio::test]
async fn sdram_fetch_reads_the_fixed_handle() {
    let rig = Rig::new(sony()).await;
    let jpeg = fake_jpeg(64);
    let j2 = jpeg.clone();
    rig.transport.on(OperationCode::GET_OBJECT_INFO, |_| {
        ok(PtpObjectInfo {
            filename: "DSC00001.JPG".into(),
            object_compressed_size: 64,
            ..Default::default()
        }
        .encoded())
    });
    rig.transport
        .on(OperationCode::GET_OBJECT, move |_| ok(j2.clone()));
    let (oi, data) = handler(&rig)
        .fetch_object(&NewObject::new(sony::SDRAM_HANDLE), None)
        .await
        .unwrap();
    assert_eq!(oi.filename, "DSC00001.JPG");
    assert_eq!(data, jpeg);
    assert_eq!(
        rig.codes(),
        vec![OperationCode::GET_OBJECT_INFO, OperationCode::GET_OBJECT]
    );
}
