//! Port of `FujifilmVendorTests.swift`.

mod common;

use std::sync::Arc;

use common::*;
use tether_ptp::device::{
    CameraEvent, NewObject, ObjectHandleDiffer, TetherProperty, VendorHandler,
};
use tether_ptp::ptp::*;
use tether_ptp::testing::{fail, ok};
use tether_ptp::vendors::fujifilm::{self, FujifilmHandler};
use tether_types::{CameraCapabilities as C, CameraVendor, CaptureDestination};

fn handler(rig: &Rig) -> FujifilmHandler {
    FujifilmHandler::new(rig.engine.clone(), rig.info.clone())
}

#[test]
fn capabilities_derive_from_operations() {
    let h = FujifilmHandler::new(idle_engine(&fuji()), fuji());
    assert_eq!(h.vendor(), CameraVendor::Fujifilm);
    assert!(h.capabilities().contains(C::REMOTE_CAPTURE));
    assert!(h.capabilities().contains(C::PROPERTY_CONTROL));
    assert!(!h.capabilities().contains(C::LIVE_VIEW));
    assert!(!h.capabilities().contains(C::SDRAM_CAPTURE));
    let x100 = info("FUJIFILM", "X100V", &[]);
    let no_capture = FujifilmHandler::new(idle_engine(&x100), x100);
    assert!(!no_capture.capabilities().contains(C::REMOTE_CAPTURE));
}

#[tokio::test]
async fn prepare_sets_priority_mode_and_seeds_differ() {
    let rig = Rig::new(fuji()).await;
    rig.transport.ok_all();
    rig.transport.on(OperationCode::GET_DEVICE_PROP_DESC, |_| {
        ok(prop_desc(
            fujifilm::prop::PRIORITY_MODE,
            DataType::UINT16,
            1,
            &[1, 2],
            true,
        ))
    });
    rig.transport
        .on(OperationCode::GET_OBJECT_HANDLES, |_| ok(handles(&[1, 2])));
    let h = handler(&rig);
    h.prepare().await.unwrap();
    assert_eq!(
        rig.codes(),
        vec![
            OperationCode::GET_DEVICE_PROP_DESC,
            OperationCode::SET_DEVICE_PROP_VALUE,
            OperationCode::GET_OBJECT_HANDLES
        ]
    );
    assert_eq!(rig.params()[1], vec![0xD207]);
    assert_eq!(
        rig.requests()[1].data_out,
        Some(PtpValue::UInt16(2).encoded())
    );
    assert!(h.differ.is_seeded());
}

#[tokio::test]
async fn prepare_leaves_priority_alone_when_already_pc() {
    let rig = Rig::new(fuji()).await;
    rig.transport.ok_all();
    rig.transport.on(OperationCode::GET_DEVICE_PROP_DESC, |_| {
        ok(prop_desc(
            fujifilm::prop::PRIORITY_MODE,
            DataType::UINT16,
            2,
            &[1, 2],
            true,
        ))
    });
    rig.transport
        .on(OperationCode::GET_OBJECT_HANDLES, |_| ok(handles(&[])));
    handler(&rig).prepare().await.unwrap();
    assert!(!rig.codes().contains(&OperationCode::SET_DEVICE_PROP_VALUE));
}

#[tokio::test]
async fn capture_uses_initiate_capture_with_zero_params() {
    let rig = Rig::new(fuji()).await;
    rig.transport.ok_all();
    handler(&rig).capture(true).await.unwrap();
    assert_eq!(rig.codes(), vec![OperationCode::INITIATE_CAPTURE]);
    assert_eq!(rig.params()[0], vec![0, 0]);
    let none = FujifilmHandler::new(rig.engine.clone(), info("FUJIFILM", "X", &[]));
    assert!(matches!(
        none.capture(true).await,
        Err(PtpError::VendorGate(_))
    ));
    assert!(handler(&rig)
        .set_capture_destination(CaptureDestination::Host)
        .await
        .is_err());
}

#[tokio::test]
async fn poll_events_reads_current_state_and_diffs_handles() {
    let rig = Rig::new(fuji()).await;
    let counter = Arc::new(Counter::default());
    let c2 = counter.clone();
    rig.transport
        .on(OperationCode::GET_OBJECT_HANDLES, move |_| {
            let n = c2.increment();
            ok(handles(if n == 1 { &[10, 11] } else { &[10, 11, 12, 13] }))
        });
    rig.transport.on(OperationCode::GET_DEVICE_PROP_VALUE, |_| {
        let mut b = ByteBuffer::new();
        b.write_u16(2);
        b.write_u16(0x5007);
        b.write_u32(280);
        b.write_u16(0xD001);
        b.write_u32(11);
        ok(b.into_bytes())
    });
    let h = handler(&rig);
    let first = h.poll_events().await.unwrap();
    assert_eq!(
        first,
        vec![
            CameraEvent::PropertyChanged(Some(TetherProperty::Aperture)),
            CameraEvent::PropertyChanged(Some(TetherProperty::PictureStyle))
        ]
    ); // first poll seeds the differ
    let second = h.poll_events().await.unwrap();
    assert_eq!(
        second,
        vec![
            CameraEvent::ObjectAdded(NewObject::new(12)),
            CameraEvent::ObjectAdded(NewObject::new(13))
        ]
    ); // RAW+JPEG: two objects, no repeated prop changes
}

#[tokio::test]
async fn pushed_object_is_not_announced_again_by_the_poll() {
    let rig = Rig::new(fuji()).await;
    let counter = Arc::new(Counter::default());
    let c2 = counter.clone();
    rig.transport
        .on(OperationCode::GET_OBJECT_HANDLES, move |_| {
            let n = c2.increment();
            ok(handles(if n == 1 { &[10, 11] } else { &[10, 11, 12] }))
        });
    rig.transport
        .on(OperationCode::GET_DEVICE_PROP_VALUE, |_| ok(vec![0, 0]));
    let h = handler(&rig);
    assert!(h.poll_events().await.unwrap().is_empty());
    let pushed = h
        .translate(&PtpEvent::new(EventCode::OBJECT_ADDED, [12]))
        .await;
    assert_eq!(pushed, Some(CameraEvent::ObjectAdded(NewObject::new(12))));
    assert!(
        h.poll_events().await.unwrap().is_empty(),
        "neither the pushed handle nor the card's old files are re-announced"
    );
}

#[tokio::test]
async fn property_read_display_and_write() {
    let rig = Rig::new(fuji()).await;
    rig.transport
        .on(OperationCode::GET_DEVICE_PROP_DESC, |req| {
            let code = DevicePropCode(req.parameters[0] as u16);
            match code {
                DevicePropCode::F_NUMBER => ok(prop_desc(
                    code,
                    DataType::UINT16,
                    200,
                    &[200, 280, 400],
                    true,
                )),
                DevicePropCode::EXPOSURE_TIME => ok(prop_desc(
                    code,
                    DataType::UINT32,
                    40,
                    &[40, 80, 10000],
                    true,
                )),
                DevicePropCode::EXPOSURE_INDEX => {
                    ok(prop_desc(code, DataType::UINT32, 160, &[160, 320], true))
                }
                fujifilm::prop::FILM_SIMULATION => {
                    ok(prop_desc(code, DataType::UINT16, 11, &[1, 11, 12], true))
                }
                DevicePropCode::WHITE_BALANCE => ok(prop_desc(
                    code,
                    DataType::UINT16,
                    0x8006,
                    &[2, 0x8006],
                    true,
                )),
                _ => fail(ResponseCode::DEVICE_PROP_NOT_SUPPORTED),
            }
        });
    rig.transport
        .on(OperationCode::SET_DEVICE_PROP_VALUE, |_| ok(vec![]));
    let h = handler(&rig);
    let props = h
        .read_properties(&[
            TetherProperty::Aperture,
            TetherProperty::ShutterSpeed,
            TetherProperty::Iso,
            TetherProperty::PictureStyle,
            TetherProperty::WhiteBalance,
            TetherProperty::CaptureDestination,
        ])
        .await
        .unwrap();
    let by = |p: TetherProperty| props.iter().find(|d| d.property == p).unwrap().clone();
    assert_eq!(by(TetherProperty::Aperture).display, "ƒ/2");
    assert_eq!(by(TetherProperty::ShutterSpeed).display, "1/250");
    let shutters: Vec<String> = by(TetherProperty::ShutterSpeed)
        .choices()
        .iter()
        .map(|c| c.display.clone())
        .collect();
    assert_eq!(shutters, ["1/250", "1/125", "1\""]);
    assert_eq!(by(TetherProperty::Iso).display, "160");
    assert_eq!(by(TetherProperty::PictureStyle).display, "Classic Chrome");
    assert_eq!(by(TetherProperty::WhiteBalance).display, "Shade");
    assert!(!by(TetherProperty::CaptureDestination).is_writable);
    h.write_property(
        TetherProperty::Iso,
        by(TetherProperty::Iso).choices()[1].raw.clone(),
    )
    .await
    .unwrap();
    let set = rig
        .transport
        .requests_for(OperationCode::SET_DEVICE_PROP_VALUE)
        .pop()
        .unwrap();
    assert_eq!(set.parameters, vec![0x500F]);
    assert_eq!(set.data_out, Some(PtpValue::UInt32(320).encoded()));
    assert_eq!(
        fujifilm::display(TetherProperty::PictureStyle, &PtpValue::UInt16(99)),
        "Film 99"
    );
}

#[test]
fn object_handle_differ_seeds_then_reports_new_handles_only() {
    let d = ObjectHandleDiffer::default();
    assert!(!d.is_seeded());
    assert!(d.diff(&[1, 2, 3]).is_empty());
    assert!(d.is_seeded());
    assert_eq!(d.diff(&[1, 2, 3, 9, 4]), vec![9, 4]);
    assert!(d.diff(&[9, 4]).is_empty()); // removals are not reported
    assert_eq!(d.diff(&[9, 4, 1]), vec![1]); // a handle that came back is new again
    d.reset();
    assert!(d.diff(&[100]).is_empty());
}

#[test]
fn current_state_parser_tolerates_truncation() {
    assert!(fujifilm::parse_current_state(&[]).unwrap().is_empty());
    let pairs = fujifilm::parse_current_state(&[2, 0, 0x07, 0x50, 1, 0, 0, 0, 0x01]).unwrap();
    assert_eq!(pairs, vec![(DevicePropCode::F_NUMBER, 1)]);
}
