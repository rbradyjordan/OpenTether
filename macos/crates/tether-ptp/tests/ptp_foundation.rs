//! Ports of `PTPFoundationTests.swift` (datasets, engine, generic handler)
//! plus the registry tests that do not need vendor handlers.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use chrono::{FixedOffset, Utc};
use tether_ptp::device::{
    handler_is, CameraEvent, GenericPtpHandler, NewObject, TetherProperty, VendorRegistry,
};
use tether_ptp::ptp::*;
use tether_ptp::testing::{fail, fake_jpeg, generic_info, ok, ScriptedTransport};
use tether_types::{CameraCapabilities, CameraVendor, TransportKind};

fn engine_for(t: &Arc<ScriptedTransport>) -> Arc<PtpEngine> {
    Arc::new(PtpEngine::new(t.clone()))
}

#[test]
fn device_info_round_trip() {
    let info = generic_info();
    let parsed = PtpDeviceInfo::parse(&info.encoded()).unwrap();
    assert_eq!(parsed, info);
    assert!(parsed.supports_op(OperationCode::INITIATE_CAPTURE));
    assert_eq!(tether_ptp::detect_vendor(&parsed), CameraVendor::Generic);
}

#[test]
fn object_info_round_trip_and_kinds() {
    let mut o = PtpObjectInfo {
        object_format: ObjectFormat::EXIF_JPEG,
        object_compressed_size: 1234,
        image_pix_width: 6000,
        image_pix_height: 4000,
        filename: "IMG_0001.JPG".into(),
        capture_date: "20261016T101500".into(),
        ..Default::default()
    };
    let p = PtpObjectInfo::parse(&o.encoded()).unwrap();
    assert_eq!(p, o);
    assert_eq!(p.media_kind(), MediaKind::Jpeg);
    assert!(p.capture_date_value().is_some());
    o.object_format = ObjectFormat::UNDEFINED;
    o.filename = "DSC_0001.NEF".into();
    assert_eq!(o.media_kind(), MediaKind::Raw);
    o.filename = "A.CR3".into();
    o.object_format = ObjectFormat::CANON_CR3;
    assert_eq!(o.media_kind(), MediaKind::Raw);
    o.filename = "clip.MP4".into();
    o.object_format = ObjectFormat::UNDEFINED;
    assert_eq!(o.media_kind(), MediaKind::Video);
}

#[test]
fn object_info_tolerates_missing_trailing_strings() {
    let o = PtpObjectInfo {
        filename: "A.JPG".into(),
        ..Default::default()
    };
    let enc = o.encoded();
    // Cut after the filename: dates and keywords missing.
    let cut = enc.len() - 3;
    let p = PtpObjectInfo::parse(&enc[..cut]).unwrap();
    assert_eq!(p.filename, "A.JPG");
    assert_eq!(p.capture_date, "");
    // Cut inside the fixed header: an error, not a panic.
    assert!(PtpObjectInfo::parse(&enc[..10]).is_err());
}

#[test]
fn device_prop_desc_enum_and_range() {
    let e = PtpDevicePropDesc {
        code: DevicePropCode::F_NUMBER,
        data_type: DataType::UINT16,
        is_writable: true,
        factory_default: PtpValue::UInt16(280),
        current: PtpValue::UInt16(400),
        form: PropForm::Enumeration(vec![
            PtpValue::UInt16(280),
            PtpValue::UInt16(400),
            PtpValue::UInt16(560),
        ]),
    };
    let pe = PtpDevicePropDesc::parse(&e.encoded()).unwrap();
    assert_eq!(pe, e);
    assert_eq!(pe.enumeration_values().map(|v| v.len()), Some(3));
    let r = PtpDevicePropDesc {
        code: DevicePropCode::EXPOSURE_BIAS_COMPENSATION,
        data_type: DataType::INT16,
        is_writable: true,
        factory_default: PtpValue::Int16(0),
        current: PtpValue::Int16(-333),
        form: PropForm::Range {
            min: PtpValue::Int16(-5000),
            max: PtpValue::Int16(5000),
            step: PtpValue::Int16(333),
        },
    };
    assert_eq!(PtpDevicePropDesc::parse(&r.encoded()).unwrap(), r);
}

#[test]
fn storage_info_round_trip() {
    let s = PtpStorageInfo {
        storage_type: 4,
        filesystem_type: 2,
        access_capability: 0,
        max_capacity: 64 << 30,
        free_space_in_bytes: 10 << 30,
        free_space_in_images: 500,
        storage_description: "SD1".into(),
        volume_label: "EOS_DIGITAL".into(),
    };
    assert_eq!(PtpStorageInfo::parse(&s.encoded()).unwrap(), s);
    assert!(s.is_removable_card());
}

#[test]
fn date_time_parsing() {
    assert!(PtpDateTime::parse("20261016T101500").is_some());
    assert!(PtpDateTime::parse("20261016T101500.5Z").is_some());
    assert!(PtpDateTime::parse("20261016T101500+0200").is_some());
    assert!(PtpDateTime::parse("garbage").is_none());
    let d = PtpDateTime::parse("20261016T101500Z").unwrap();
    assert_eq!(PtpDateTime::format(d, &Utc), "20261016T101500");
    let plus2 = PtpDateTime::parse("20261016T101500+0200").unwrap();
    assert_eq!(PtpDateTime::format(plus2, &Utc), "20261016T081500");
    let zone = FixedOffset::east_opt(2 * 3600).unwrap();
    assert_eq!(PtpDateTime::format(plus2, &zone), "20261016T101500");
}

#[test]
fn jpeg_payload_extraction() {
    let mut framed = vec![0xAA; 64];
    framed.extend(fake_jpeg(100));
    framed.extend([0xBB; 8]);
    let jpeg = tether_types::jpeg_payload(&framed).unwrap();
    assert_eq!(&jpeg[..2], &[0xFF, 0xD8]);
    assert_eq!(&jpeg[jpeg.len() - 2..], &[0xFF, 0xD9]);
    assert_eq!(jpeg.len(), 100);
}

// MARK: Engine

#[tokio::test]
async fn connect_reads_device_info_and_opens_session() {
    let t = ScriptedTransport::generic();
    let engine = engine_for(&t);
    let info = engine.connect(1).await.unwrap();
    assert_eq!(info.model, "PTP-1");
    let codes: Vec<_> = t.requests().iter().map(|r| r.code).collect();
    assert_eq!(
        codes,
        vec![OperationCode::GET_DEVICE_INFO, OperationCode::OPEN_SESSION]
    );
    assert!(engine.is_session_open());
    assert_eq!(engine.session_id(), 1);
}

#[tokio::test]
async fn partial_download_chunks_and_reports_progress() {
    let t = ScriptedTransport::generic();
    let payload: Vec<u8> = (0..2500).map(|i| (i & 0xFF) as u8).collect();
    let p2 = payload.clone();
    t.on(OperationCode::GET_PARTIAL_OBJECT, move |req| {
        let off = req.parameters[1] as usize;
        let want = req.parameters[2] as usize;
        let end = p2.len().min(off + want);
        ok(p2[off..end].to_vec())
    });
    let engine = engine_for(&t);
    engine.connect(1).await.unwrap();
    engine.set_partial_chunk_size(1000);
    let seen = Arc::new(Mutex::new(Vec::new()));
    let s2 = seen.clone();
    let progress: ProgressFn = Arc::new(move |done, total| s2.lock().unwrap().push((done, total)));
    let data = engine
        .download(0x42, Some(payload.len() as u32), Some(progress))
        .await
        .unwrap();
    assert_eq!(data, payload);
    assert_eq!(t.requests_for(OperationCode::GET_PARTIAL_OBJECT).len(), 3);
    assert_eq!(seen.lock().unwrap().last(), Some(&(2500, Some(2500))));
}

#[tokio::test]
async fn download_falls_back_to_get_object_without_size() {
    let t = ScriptedTransport::generic();
    t.on(OperationCode::GET_OBJECT, |_| ok(vec![1, 2, 3]));
    let engine = engine_for(&t);
    engine.connect(1).await.unwrap();
    assert_eq!(engine.download(1, None, None).await.unwrap(), vec![1, 2, 3]);
    assert!(t.requests_for(OperationCode::GET_PARTIAL_OBJECT).is_empty());
}

#[tokio::test]
async fn device_busy_is_retried() {
    let t = ScriptedTransport::generic();
    let counter = Arc::new(AtomicUsize::new(0));
    let c2 = counter.clone();
    t.on(OperationCode::GET_STORAGE_IDS, move |_| {
        let n = c2.fetch_add(1, Ordering::SeqCst) + 1;
        if n < 3 {
            return fail(ResponseCode::DEVICE_BUSY);
        }
        let mut b = ByteBuffer::new();
        b.write_u32_array(&[0x0001_0001]);
        ok(b.into_bytes())
    });
    let engine = engine_for(&t);
    engine.connect(1).await.unwrap();
    assert_eq!(engine.get_storage_ids().await.unwrap(), vec![0x0001_0001]);
    assert_eq!(counter.load(Ordering::SeqCst), 3);
}

#[tokio::test]
async fn errors_carry_the_response_code() {
    let t = ScriptedTransport::generic();
    t.on(OperationCode::INITIATE_CAPTURE, |_| {
        fail(ResponseCode::ACCESS_DENIED)
    });
    let engine = engine_for(&t);
    engine.connect(1).await.unwrap();
    let e = engine.initiate_capture(0, None).await.unwrap_err();
    assert_eq!(e.response_code(), Some(ResponseCode::ACCESS_DENIED));
    assert!(e.to_string().contains("AccessDenied"));
    assert_eq!(e.to_string(), "InitiateCapture failed: AccessDenied");
}

#[tokio::test]
async fn malformed_data_is_an_error_not_a_panic() {
    let t = ScriptedTransport::generic();
    t.on(OperationCode::GET_OBJECT_INFO, |_| ok(vec![1, 2, 3]));
    t.on(OperationCode::GET_STORAGE_IDS, |_| {
        ok(vec![0xFF, 0xFF, 0xFF, 0x7F])
    });
    let engine = engine_for(&t);
    engine.connect(1).await.unwrap();
    assert!(matches!(
        engine.get_object_info(1).await,
        Err(PtpError::Read(_))
    ));
    assert!(engine.get_storage_ids().await.is_err());
}

#[tokio::test]
async fn log_records_transactions() {
    let t = ScriptedTransport::generic();
    t.on(OperationCode::GET_STORAGE_IDS, |_| {
        let mut b = ByteBuffer::new();
        b.write_u32_array(&[1]);
        ok(b.into_bytes())
    });
    let log = Arc::new(PtpLog::new(3));
    let engine = PtpEngine::with_log(t.clone(), Some(log.clone()));
    engine.connect(1).await.unwrap();
    engine.get_storage_ids().await.unwrap();
    engine.get_storage_ids().await.unwrap();
    let recent = log.recent();
    assert_eq!(recent.len(), 3); // capped
    assert!(recent.last().unwrap().line().contains("GetStorageIDs"));
}

#[tokio::test]
async fn disconnect_closes_session_and_transport() {
    let t = ScriptedTransport::generic();
    let engine = engine_for(&t);
    engine.connect(1).await.unwrap();
    engine.disconnect().await;
    assert!(!engine.is_session_open());
    assert!(!t.is_open());
    assert_eq!(
        t.requests().last().map(|r| r.code),
        Some(OperationCode::CLOSE_SESSION)
    );
}

// MARK: Generic handler

#[test]
fn capabilities_from_device_info() {
    let t = ScriptedTransport::generic();
    let h = GenericPtpHandler::new(engine_for(&t), generic_info(), None);
    use tether_ptp::VendorHandler;
    assert!(h
        .capabilities()
        .contains(CameraCapabilities::REMOTE_CAPTURE));
    assert!(h
        .capabilities()
        .contains(CameraCapabilities::PARTIAL_TRANSFER));
    assert!(!h.capabilities().contains(CameraCapabilities::IMPORT_ONLY));
    let mut info = generic_info();
    info.operations_supported
        .retain(|c| *c != OperationCode::INITIATE_CAPTURE);
    let h2 = GenericPtpHandler::new(engine_for(&t), info, None);
    assert!(h2.capabilities().contains(CameraCapabilities::IMPORT_ONLY));
}

#[tokio::test]
async fn translate_events() {
    use tether_ptp::VendorHandler;
    let t = ScriptedTransport::generic();
    let h = GenericPtpHandler::new(engine_for(&t), generic_info(), None);
    let added = h
        .translate(&PtpEvent::new(EventCode::OBJECT_ADDED, [0x1234]))
        .await;
    assert_eq!(
        added,
        Some(CameraEvent::ObjectAdded(NewObject::new(0x1234)))
    );
    let zero = h
        .translate(&PtpEvent::new(EventCode::OBJECT_ADDED, [0]))
        .await;
    assert_eq!(zero, None);
    let prop = h
        .translate(&PtpEvent::new(EventCode::DEVICE_PROP_CHANGED, [0x5007]))
        .await;
    assert_eq!(
        prop,
        Some(CameraEvent::PropertyChanged(Some(TetherProperty::Aperture)))
    );
    let reset = h
        .translate(&PtpEvent::new(EventCode::DEVICE_RESET, []))
        .await;
    assert_eq!(reset, Some(CameraEvent::Disconnected));
}

#[tokio::test]
async fn read_and_write_standard_properties() {
    use tether_ptp::VendorHandler;
    let t = ScriptedTransport::generic();
    t.on(OperationCode::GET_DEVICE_PROP_DESC, |req| {
        let d = PtpDevicePropDesc {
            code: DevicePropCode(req.parameters[0] as u16),
            data_type: DataType::UINT16,
            is_writable: true,
            factory_default: PtpValue::UInt16(280),
            current: PtpValue::UInt16(400),
            form: PropForm::Enumeration(vec![PtpValue::UInt16(280), PtpValue::UInt16(400)]),
        };
        ok(d.encoded())
    });
    t.on(OperationCode::SET_DEVICE_PROP_VALUE, |_| ok(Vec::new()));
    let engine = engine_for(&t);
    engine.connect(1).await.unwrap();
    let h = GenericPtpHandler::new(engine, generic_info(), None);
    let props = h
        .read_properties(&[TetherProperty::Aperture, TetherProperty::ColorTemperature])
        .await
        .unwrap();
    assert_eq!(props.len(), 1);
    assert_eq!(props[0].display, "ƒ/4");
    let shown: Vec<_> = props[0]
        .choices()
        .iter()
        .map(|c| c.display.clone())
        .collect();
    assert_eq!(shown, vec!["ƒ/2.8", "ƒ/4"]);
    h.write_property(TetherProperty::Aperture, PtpValue::UInt16(280))
        .await
        .unwrap();
    assert_eq!(
        t.requests_for(OperationCode::SET_DEVICE_PROP_VALUE)
            .first()
            .and_then(|r| r.data_out.clone()),
        Some(PtpValue::UInt16(280).encoded())
    );
    assert!(h
        .write_property(TetherProperty::ColorTemperature, PtpValue::UInt16(1))
        .await
        .is_err());
}

#[tokio::test]
async fn polling_finds_new_objects_and_fetches_them() {
    use tether_ptp::VendorHandler;
    let t = ScriptedTransport::generic();
    let handles = Arc::new(Mutex::new(vec![1u32, 2]));
    let h2 = handles.clone();
    t.on(OperationCode::GET_OBJECT_HANDLES, move |_| {
        let mut b = ByteBuffer::new();
        b.write_u32_array(&h2.lock().unwrap());
        ok(b.into_bytes())
    });
    let jpeg = fake_jpeg(1500);
    let j2 = jpeg.clone();
    t.on(OperationCode::GET_OBJECT_INFO, move |_| {
        ok(PtpObjectInfo {
            object_compressed_size: j2.len() as u32,
            filename: "IMG_0003.JPG".into(),
            ..Default::default()
        }
        .encoded())
    });
    let j3 = jpeg.clone();
    t.on(OperationCode::GET_PARTIAL_OBJECT, move |req| {
        let off = req.parameters[1] as usize;
        let end = j3.len().min(off + req.parameters[2] as usize);
        ok(j3[off..end].to_vec())
    });
    let engine = engine_for(&t);
    engine.connect(1).await.unwrap();
    let h = GenericPtpHandler::new(engine, generic_info(), Some("hint".into()));
    h.prepare().await.unwrap();
    let first = h.poll_events().await.unwrap();
    assert_eq!(first, vec![CameraEvent::Warning("hint".into())]);
    handles.lock().unwrap().push(3);
    let events = h.poll_events().await.unwrap();
    assert_eq!(events, vec![CameraEvent::ObjectAdded(NewObject::new(3))]);
    let (info, data) = h.fetch_object(&NewObject::new(3), None).await.unwrap();
    assert_eq!(info.filename, "IMG_0003.JPG");
    assert_eq!(data, jpeg);
}

// MARK: Registry

fn info_with(manufacturer: &str, model: &str, extra_ops: &[u16], ext: u32) -> PtpDeviceInfo {
    let mut info = generic_info();
    info.manufacturer = manufacturer.into();
    info.model = model.into();
    info.vendor_extension_id = ext;
    info.operations_supported
        .extend(extra_ops.iter().map(|o| OperationCode(*o)));
    info
}

#[tokio::test]
async fn registry_falls_back_to_generic() {
    let t = ScriptedTransport::generic();
    let mut info = generic_info();
    info.manufacturer = "Hasselblad".into();
    let h = VendorRegistry::make_handler(engine_for(&t), info, TransportKind::Usb);
    assert!(handler_is::<GenericPtpHandler>(h.as_ref()));
    assert_eq!(h.vendor(), CameraVendor::Hasselblad);
    assert!(handler_is::<GenericPtpHandler>(
        VendorRegistry::make_handler(engine_for(&t), generic_info(), TransportKind::Usb).as_ref()
    ));
}

#[tokio::test]
async fn bodies_without_vendor_mode_import_instead_of_failing() {
    let t = ScriptedTransport::generic();
    // A PowerShot without EOS remote mode, a Sony not in PC Remote.
    let mut powershot = info_with("Canon Inc.", "PowerShot G7 X", &[], 0);
    powershot
        .operations_supported
        .retain(|c| *c != OperationCode::INITIATE_CAPTURE);
    let h = VendorRegistry::make_handler(engine_for(&t), powershot, TransportKind::Usb);
    assert!(handler_is::<GenericPtpHandler>(h.as_ref()));
    assert!(h.capabilities().contains(CameraCapabilities::IMPORT_ONLY));
    let sony = info_with("Sony Corporation", "ILCE-7M4", &[], 0x11);
    let s = VendorRegistry::make_handler(engine_for(&t), sony, TransportKind::Usb);
    assert!(handler_is::<GenericPtpHandler>(s.as_ref()));
    // Not seeded (no prepare), so only the hint comes back, exactly once.
    let events = s.poll_events().await.unwrap();
    assert!(events
        .iter()
        .any(|e| matches!(e, CameraEvent::Warning(w) if w.contains("PC Remote"))));
    let again = s.poll_events().await.unwrap();
    assert!(!again.iter().any(|e| matches!(e, CameraEvent::Warning(_))));
}

#[test]
fn wired_only_brands_over_ptpip_get_the_generic_importer() {
    // A dedicated (stand-in) Olympus factory is bypassed over PTP/IP: the
    // brand is wired-only, so it gets the generic handler there.
    struct Marker(GenericPtpHandler);
    #[async_trait::async_trait]
    impl tether_ptp::VendorHandler for Marker {
        fn vendor(&self) -> CameraVendor {
            CameraVendor::Olympus
        }
        fn capabilities(&self) -> CameraCapabilities {
            CameraCapabilities::empty()
        }
        async fn prepare(&self) -> PtpResult<()> {
            Ok(())
        }
        async fn teardown(&self) {}
        async fn set_capture_destination(
            &self,
            _d: tether_types::CaptureDestination,
        ) -> PtpResult<()> {
            Ok(())
        }
        async fn capture(&self, _af: bool) -> PtpResult<()> {
            Ok(())
        }
        async fn translate(&self, e: &PtpEvent) -> Option<CameraEvent> {
            self.0.translate(e).await
        }
        async fn read_properties(
            &self,
            _p: &[TetherProperty],
        ) -> PtpResult<Vec<tether_ptp::PropertyDescriptor>> {
            Ok(vec![])
        }
        async fn write_property(&self, _p: TetherProperty, _r: PtpValue) -> PtpResult<()> {
            Ok(())
        }
        async fn fetch_object(
            &self,
            o: &NewObject,
            p: Option<ProgressFn>,
        ) -> PtpResult<(PtpObjectInfo, Vec<u8>)> {
            self.0.fetch_object(o, p).await
        }
    }
    VendorRegistry::register(
        CameraVendor::Olympus,
        Arc::new(|engine, info| Arc::new(Marker(GenericPtpHandler::new(engine, info, None)))),
    );
    assert!(VendorRegistry::registered().contains(&CameraVendor::Olympus));
    let t = ScriptedTransport::generic();
    let olympus = info_with("OLYMPUS", "E-M1MarkIII", &[0x9481], 0x06);
    let usb = VendorRegistry::make_handler(engine_for(&t), olympus.clone(), TransportKind::Usb);
    assert!(handler_is::<Marker>(usb.as_ref()));
    let wifi = VendorRegistry::make_handler(engine_for(&t), olympus, TransportKind::PtpIp);
    assert!(handler_is::<GenericPtpHandler>(wifi.as_ref()));
}

#[test]
fn new_brands_are_recognised() {
    let d =
        |m: &str, model: &str, ext: u32| tether_ptp::detect_vendor(&info_with(m, model, &[], ext));
    assert_eq!(
        d("RICOH IMAGING COMPANY, LTD.", "PENTAX K-3 Mark III", 0),
        CameraVendor::Pentax
    );
    assert_eq!(
        d("RICOH IMAGING COMPANY, LTD.", "RICOH GR III", 0),
        CameraVendor::Ricoh
    );
    assert_eq!(d("RICOH", "RICOH THETA Z1", 0), CameraVendor::Osc);
    assert_eq!(d("SIGMA", "fp L", 0), CameraVendor::Sigma);
    assert_eq!(d("Hasselblad", "X2D 100C", 0), CameraVendor::Hasselblad);
    assert_eq!(d("", "", 0x0D), CameraVendor::Pentax);
    assert_eq!(d("", "", 0x1A), CameraVendor::Samsung);
    assert_eq!(d("GoPro", "HERO12 Black", 0), CameraVendor::Gopro);
}
