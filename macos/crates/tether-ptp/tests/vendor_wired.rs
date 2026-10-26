//! Port of `WiredVendorTests.swift`: Olympus, Panasonic and Leica, the
//! wired-only brands built on the generic handler plus a vendor capture opcode.

mod common;

use std::sync::Arc;

use common::*;
use tether_ptp::device::{CameraEvent, NewObject, TetherProperty, VendorHandler};
use tether_ptp::ptp::*;
use tether_ptp::testing::{fail, fake_jpeg, ok};
use tether_ptp::vendors::leica::{self, LeicaHandler};
use tether_ptp::vendors::olympus::{self, OlympusHandler};
use tether_ptp::vendors::panasonic::{self, PanasonicHandler, PanasonicPropertyValue};
use tether_types::{CameraCapabilities as C, CameraVendor, CaptureDestination, LiveViewQuality};

// MARK: Olympus

#[tokio::test]
async fn olympus_capabilities_prepare_and_capture() {
    let rig = Rig::new(olympus()).await;
    rig.transport.ok_all();
    rig.transport
        .on(OperationCode::GET_OBJECT_HANDLES, |_| ok(handles(&[1])));
    let h = OlympusHandler::new(rig.engine.clone(), rig.info.clone());
    assert_eq!(h.vendor(), CameraVendor::Olympus);
    assert!(h.capabilities().contains(C::REMOTE_CAPTURE));
    assert!(h.capabilities().contains(C::LIVE_VIEW));
    assert!(h.capabilities().contains(C::AUTOFOCUS));
    h.prepare().await.unwrap();
    assert_eq!(
        rig.codes(),
        vec![
            OperationCode::SET_DEVICE_PROP_VALUE,
            OperationCode::GET_OBJECT_HANDLES
        ]
    );
    assert_eq!(rig.params()[0], vec![0xD052]);
    assert_eq!(
        rig.requests()[0].data_out,
        Some(PtpValue::UInt8(1).encoded())
    );
    h.capture(true).await.unwrap();
    let codes = rig.codes();
    assert_eq!(
        &codes[codes.len() - 2..],
        &[olympus::op::CAPTURE, olympus::op::CAPTURE]
    );
    let params = rig.params();
    assert_eq!(&params[params.len() - 2..], &[vec![0x3], vec![0x6]]);
    let tg6 = info("OLYMPUS", "TG-6", &[]);
    let plain = OlympusHandler::new(rig.engine.clone(), tg6);
    assert!(!plain.capabilities().contains(C::REMOTE_CAPTURE));
    h.teardown().await;
    assert_eq!(
        rig.requests().last().unwrap().data_out,
        Some(PtpValue::UInt8(0).encoded())
    );
}

#[tokio::test]
async fn olympus_events_fall_back_to_handle_diff() {
    let rig = Rig::new(olympus()).await;
    let counter = Arc::new(Counter::default());
    let c2 = counter.clone();
    rig.transport
        .on(OperationCode::GET_OBJECT_HANDLES, move |_| {
            let n = c2.increment();
            ok(handles(if n == 1 { &[1] } else { &[1, 2] }))
        });
    let h = OlympusHandler::new(rig.engine.clone(), rig.info.clone());
    assert!(h.poll_events().await.unwrap().is_empty());
    assert_eq!(
        h.poll_events().await.unwrap(),
        vec![CameraEvent::ObjectAdded(NewObject::new(2))]
    );
    let pc = h
        .translate(&PtpEvent::new(olympus::event::PROPERTY_CHANGED, [0x500D]))
        .await;
    assert_eq!(
        pc,
        Some(CameraEvent::PropertyChanged(Some(
            TetherProperty::ShutterSpeed
        )))
    );
    let cc = h
        .translate(&PtpEvent::new(olympus::event::CAPTURE_COMPLETE, []))
        .await;
    assert_eq!(cc, Some(CameraEvent::CaptureComplete));
}

#[tokio::test]
async fn olympus_live_view_toggles_mode_and_finds_jpeg() {
    let rig = Rig::new(info_full(
        "OLYMPUS",
        "OM-1",
        &[0x9481, 0x9484],
        &[0xD052, 0xD06D],
        true,
        0x06,
    ))
    .await;
    rig.transport.ok_all();
    let jpeg = fake_jpeg(90);
    let mut payload = vec![9u8; 20];
    payload.extend(&jpeg);
    rig.transport
        .on(olympus::op::GET_LIVE_VIEW_IMAGE, move |_| {
            ok(payload.clone())
        });
    let h = OlympusHandler::new(rig.engine.clone(), rig.info.clone());
    h.start_live_view(LiveViewQuality::Medium).await.unwrap();
    assert_eq!(rig.params()[0], vec![0xD06D]);
    assert_eq!(
        rig.requests()[0].data_out,
        Some(PtpValue::UInt32(1).encoded())
    );
    let f = h.next_live_view_frame().await.unwrap().unwrap();
    assert_eq!(f.jpeg, jpeg);
    assert_eq!(
        rig.transport.requests_for(olympus::op::GET_LIVE_VIEW_IMAGE)[0].parameters,
        vec![olympus::LIVE_VIEW_PARAM]
    );
    h.stop_live_view().await;
    assert_eq!(
        rig.requests().last().unwrap().data_out,
        Some(PtpValue::UInt32(0).encoded())
    );
}

// MARK: Panasonic

#[tokio::test]
async fn panasonic_capabilities_and_capture() {
    let rig = Rig::new(panasonic()).await;
    rig.transport.ok_all();
    rig.transport
        .on(OperationCode::GET_OBJECT_HANDLES, |_| ok(handles(&[])));
    let h = PanasonicHandler::new(rig.engine.clone(), rig.info.clone());
    assert_eq!(h.vendor(), CameraVendor::Panasonic);
    for c in [
        C::REMOTE_CAPTURE,
        C::CARD_CAPTURE,
        C::LIVE_VIEW,
        C::PROPERTY_CONTROL,
        C::AUTOFOCUS,
    ] {
        assert!(h.capabilities().contains(c), "{c:?}");
    }
    h.prepare().await.unwrap();
    h.capture(true).await.unwrap();
    assert_eq!(
        rig.codes(),
        vec![
            OperationCode::GET_OBJECT_HANDLES,
            panasonic::op::INITIATE_CAPTURE
        ]
    );
    assert_eq!(rig.params()[1], vec![0x0300_0011]);
    h.start_live_view(LiveViewQuality::Medium).await.unwrap();
    let last = rig.requests().pop().unwrap();
    assert_eq!(last.code, panasonic::op::LIVEVIEW);
    assert_eq!(last.parameters, vec![0x0D00_0010]);
    let jpeg = fake_jpeg(40);
    let j2 = jpeg.clone();
    rig.transport
        .on(panasonic::op::LIVEVIEW_IMAGE, move |_| ok(j2.clone()));
    assert_eq!(h.next_live_view_frame().await.unwrap().unwrap().jpeg, jpeg);
    h.stop_live_view().await;
    assert_eq!(rig.params().last().unwrap(), &vec![0x0D00_0011]);
}

#[tokio::test]
async fn panasonic_property_payloads_and_display() {
    let rig = Rig::new(panasonic()).await;
    rig.transport.ok_all();
    rig.transport.on(panasonic::op::GET_PROPERTY, |req| {
        let code = req.parameters[0];
        let value = match code {
            panasonic::prop::SHUTTER_SPEED => 125_000,
            panasonic::prop::APERTURE => 28,
            panasonic::prop::ISO => 800,
            panasonic::prop::EXPOSURE => (-2i32) as u32,
            panasonic::prop::WHITE_BALANCE => 0x8008,
            _ => return fail(ResponseCode::DEVICE_PROP_NOT_SUPPORTED),
        };
        ok(PanasonicPropertyValue::new(code, value).encoded())
    });
    let h = PanasonicHandler::new(rig.engine.clone(), rig.info.clone());
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
    let by = |p: TetherProperty| props.iter().find(|d| d.property == p);
    assert_eq!(by(TetherProperty::ShutterSpeed).unwrap().display, "1/125");
    assert_eq!(by(TetherProperty::Aperture).unwrap().display, "ƒ/2.8");
    assert_eq!(by(TetherProperty::Iso).unwrap().display, "800");
    assert_eq!(
        by(TetherProperty::ExposureCompensation).unwrap().display,
        "-0.7"
    );
    assert_eq!(by(TetherProperty::WhiteBalance).unwrap().display, "Cloudy");
    assert!(by(TetherProperty::BatteryLevel).is_none()); // the body did not answer
    assert!(!by(TetherProperty::CaptureDestination).unwrap().is_writable);
    h.write_property(TetherProperty::Aperture, PtpValue::UInt32(40))
        .await
        .unwrap();
    let set = rig
        .transport
        .requests_for(panasonic::op::SET_PROPERTY)
        .pop()
        .unwrap();
    assert_eq!(set.parameters, vec![panasonic::prop::APERTURE]);
    assert_eq!(
        set.data_out.unwrap(),
        vec![0x40, 0x00, 0x00, 0x02, 4, 0, 0, 0, 40, 0, 0, 0]
    );
    assert_eq!(panasonic::shutter_display(0x8000_0000 | 4000), "4\"");
    assert_eq!(panasonic::shutter_display(0xFFFF_FFFF), "Bulb");
    let parsed =
        PanasonicPropertyValue::parse(&[0x30, 0, 0, 0x02, 2, 0, 0, 0, 0x34, 0x12]).unwrap();
    assert_eq!(parsed.value, 0x1234);
    assert!(h
        .write_property(TetherProperty::BatteryLevel, PtpValue::UInt32(1))
        .await
        .is_err());
}

#[tokio::test]
async fn panasonic_vendor_object_events_mark_the_differ() {
    let rig = Rig::new(panasonic()).await;
    let counter = Arc::new(Counter::default());
    let c2 = counter.clone();
    rig.transport
        .on(OperationCode::GET_OBJECT_HANDLES, move |_| {
            let n = c2.increment();
            ok(handles(if n == 1 { &[1] } else { &[1, 5] }))
        });
    let h = PanasonicHandler::new(rig.engine.clone(), rig.info.clone());
    h.prepare().await.unwrap();
    let e = h
        .translate(&PtpEvent::new(panasonic::event::OBJECT_ADDED_SDRAM, [5]))
        .await;
    assert_eq!(
        e,
        Some(CameraEvent::ObjectAdded(NewObject {
            in_sdram: true,
            ..NewObject::new(5)
        }))
    );
    assert_eq!(
        h.translate(&PtpEvent::new(panasonic::event::OBJECT_ADDED, [0]))
            .await,
        None
    );
    assert!(h.poll_events().await.unwrap().is_empty());
}

// MARK: Leica

#[tokio::test]
async fn leica_session_gate_and_release_stage_capture() {
    let rig = Rig::new(leica()).await;
    rig.transport.ok_all();
    rig.transport
        .on(OperationCode::GET_OBJECT_HANDLES, |_| ok(handles(&[5])));
    let h = LeicaHandler::new(rig.engine.clone(), rig.info.clone());
    assert_eq!(h.vendor(), CameraVendor::Leica);
    assert!(h.capabilities().contains(C::REMOTE_CAPTURE));
    assert!(h.capabilities().contains(C::AUTOFOCUS));
    h.prepare().await.unwrap();
    assert_eq!(
        rig.codes(),
        vec![
            leica::op::OPEN_LE_SESSION,
            OperationCode::GET_OBJECT_HANDLES
        ]
    );
    assert_eq!(rig.params()[0], vec![1]);
    h.capture(true).await.unwrap();
    let codes = rig.codes();
    assert_eq!(&codes[codes.len() - 3..], &[leica::op::RELEASE_STAGE; 3]);
    let params = rig.params();
    assert_eq!(&params[params.len() - 3..], &[vec![1], vec![2], vec![0]]);
    h.capture(false).await.unwrap();
    let params = rig.params();
    assert_eq!(&params[params.len() - 2..], &[vec![2], vec![0]]);
    h.teardown().await;
    assert_eq!(rig.codes().last(), Some(&leica::op::CLOSE_LE_SESSION));
    // Closed once only.
    let n = rig.codes().len();
    h.teardown().await;
    assert_eq!(rig.codes().len(), n);
}

#[tokio::test]
async fn leica_properties_are_standard_and_destination_is_card_only() {
    let rig = Rig::new(leica()).await;
    rig.transport
        .on(OperationCode::GET_DEVICE_PROP_DESC, |req| {
            let code = DevicePropCode(req.parameters[0] as u16);
            ok(prop_desc(code, DataType::UINT16, 560, &[400, 560], true))
        });
    rig.transport
        .on(OperationCode::SET_DEVICE_PROP_VALUE, |_| ok(vec![]));
    let h = LeicaHandler::new(rig.engine.clone(), rig.info.clone());
    let props = h
        .read_properties(&[TetherProperty::Aperture, TetherProperty::CaptureDestination])
        .await
        .unwrap();
    assert_eq!(props[0].display, "ƒ/5.6");
    assert_eq!(
        props.last().unwrap().property,
        TetherProperty::CaptureDestination
    );
    h.write_property(TetherProperty::Aperture, props[0].choices()[0].raw.clone())
        .await
        .unwrap();
    assert_eq!(
        rig.transport
            .requests_for(OperationCode::SET_DEVICE_PROP_VALUE)
            .pop()
            .unwrap()
            .data_out,
        Some(PtpValue::UInt16(400).encoded())
    );
    assert!(matches!(
        h.set_capture_destination(CaptureDestination::Host).await,
        Err(PtpError::Unsupported(_))
    ));
}
