//! Port of `VendorRegistryTests.swift` (built-ins installed).

mod common;

use common::*;
use tether_ptp::device::{handler_is, CameraEvent, GenericPtpHandler, VendorRegistry};
use tether_ptp::testing::{generic_info, ScriptedTransport};
use tether_ptp::vendors::*;
use tether_ptp::{install_built_ins, PtpEngine, VendorHandler};
use tether_types::{CameraCapabilities, CameraVendor, TransportKind};

use std::sync::Arc;

fn setup() -> Arc<PtpEngine> {
    install_built_ins();
    install_built_ins(); // idempotent
    Arc::new(PtpEngine::new(ScriptedTransport::generic()))
}

fn make(
    engine: &Arc<PtpEngine>,
    info: tether_ptp::PtpDeviceInfo,
    kind: TransportKind,
) -> Arc<dyn VendorHandler> {
    VendorRegistry::make_handler(engine.clone(), info, kind)
}

#[test]
fn every_built_in_vendor_is_registered() {
    setup();
    let registered = VendorRegistry::registered();
    for v in BUILT_IN_VENDORS {
        assert!(registered.contains(&v), "{v:?}");
    }
    assert!(!registered.contains(&CameraVendor::Ricoh));
    assert!(
        !registered.contains(&CameraVendor::Hasselblad),
        "generic handler, no dedicated one"
    );
}

#[test]
fn manufacturer_strings_resolve_to_handlers() {
    let e = setup();
    let usb = TransportKind::Usb;
    assert!(handler_is::<CanonHandler>(make(&e, canon(), usb).as_ref()));
    assert!(handler_is::<NikonHandler>(
        make(&e, nikon_z(), usb).as_ref()
    ));
    assert!(handler_is::<SonyHandler>(make(&e, sony(), usb).as_ref()));
    assert!(handler_is::<FujifilmHandler>(
        make(&e, fuji(), usb).as_ref()
    ));
    assert!(handler_is::<OlympusHandler>(
        make(&e, olympus(), usb).as_ref()
    ));
    assert!(handler_is::<PanasonicHandler>(
        make(&e, panasonic(), usb).as_ref()
    ));
    assert!(handler_is::<LeicaHandler>(make(&e, leica(), usb).as_ref()));
    // OM System branding and vendor-extension-only detection still land on the right class.
    assert!(handler_is::<OlympusHandler>(
        make(&e, info("OM Digital Solutions", "OM-1", &[0x9481]), usb).as_ref()
    ));
    assert!(handler_is::<CanonHandler>(
        make(&e, info_full("", "", &[0x9114], &[], true, 0x0B), usb).as_ref()
    ));
}

#[tokio::test]
async fn bodies_without_vendor_mode_import_instead_of_failing() {
    let e = setup();
    // A PowerShot without EOS remote mode, a Sony not in PC Remote.
    let powershot = make(
        &e,
        info("Canon Inc.", "PowerShot G7 X", &[0x1007]),
        TransportKind::Usb,
    );
    assert!(handler_is::<GenericPtpHandler>(powershot.as_ref()));
    assert!(powershot
        .capabilities()
        .contains(CameraCapabilities::IMPORT_ONLY));
    let sony = make(&e, sony_mass_storage(), TransportKind::Usb);
    assert!(handler_is::<GenericPtpHandler>(sony.as_ref()));
    let events = sony.poll_events().await.unwrap();
    assert!(
        events
            .iter()
            .any(|e| matches!(e, CameraEvent::Warning(w) if w.contains("PC Remote"))),
        "hint shown once"
    );
    let again = sony.poll_events().await.unwrap();
    assert!(!again.iter().any(|e| matches!(e, CameraEvent::Warning(_))));
}

#[test]
fn unknown_hasselblad_and_wireless_wired_only_fall_back_to_generic() {
    let e = setup();
    let usb = TransportKind::Usb;
    let ip = TransportKind::PtpIp;
    assert!(handler_is::<GenericPtpHandler>(
        make(&e, generic_info(), usb).as_ref()
    ));
    let mut hb = generic_info();
    hb.manufacturer = "Hasselblad".into();
    assert!(handler_is::<GenericPtpHandler>(make(&e, hb, usb).as_ref()));
    // Wired-only brands over PTP/IP get the generic importer; wireless-capable brands keep theirs.
    assert!(handler_is::<GenericPtpHandler>(
        make(&e, olympus(), ip).as_ref()
    ));
    assert!(handler_is::<GenericPtpHandler>(
        make(&e, panasonic(), ip).as_ref()
    ));
    assert!(handler_is::<GenericPtpHandler>(
        make(&e, leica(), ip).as_ref()
    ));
    assert!(handler_is::<CanonHandler>(make(&e, canon(), ip).as_ref()));
    assert!(handler_is::<FujifilmHandler>(make(&e, fuji(), ip).as_ref()));
    assert!(handler_is::<NikonHandler>(make(&e, nikon_z(), ip).as_ref()));
    assert!(handler_is::<SonyHandler>(make(&e, sony(), ip).as_ref()));
}

#[test]
fn new_brands_are_recognised() {
    let d = |i: tether_ptp::PtpDeviceInfo| tether_ptp::detect_vendor(&i);
    assert_eq!(
        d(info(
            "RICOH IMAGING COMPANY, LTD.",
            "PENTAX K-3 Mark III",
            &[]
        )),
        CameraVendor::Pentax
    );
    assert_eq!(
        d(info("RICOH IMAGING COMPANY, LTD.", "RICOH GR III", &[])),
        CameraVendor::Ricoh
    );
    assert_eq!(d(info("RICOH", "RICOH THETA Z1", &[])), CameraVendor::Osc);
    assert_eq!(d(info("SIGMA", "fp L", &[])), CameraVendor::Sigma);
    assert_eq!(
        d(info("Hasselblad", "X2D 100C", &[])),
        CameraVendor::Hasselblad
    );
    assert_eq!(
        d(info_full("", "", &[], &[], true, 0x0D)),
        CameraVendor::Pentax
    );
    assert_eq!(
        d(info_full("", "", &[], &[], true, 0x1A)),
        CameraVendor::Samsung
    );
    assert_eq!(d(info("GoPro", "HERO12 Black", &[])), CameraVendor::Gopro);
    assert!(
        CameraVendor::Hasselblad.supports_wired_control(),
        "capability comes from the body, not a block list"
    );
}
