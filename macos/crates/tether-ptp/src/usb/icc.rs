//! ImageCaptureCore (macOS): the USB camera browser and the PTP transport
//! over `ICCameraDevice.requestSendPTPCommand`.
//!
//! # Threading model
//!
//! ImageCaptureCore delivers `ICDeviceBrowser` and `ICDevice` delegate
//! callbacks on the **main thread's run loop**. In the Tauri app the main
//! thread runs the AppKit event loop, so callbacks flow without any extra
//! work; in a plain CLI or `cargo test` nothing pumps the main run loop and
//! the browser never reports devices.
//!
//! - Every `ICDeviceBrowser` call is made on the main thread. From any other
//!   thread the work is queued with `dispatch_async` on the main queue and
//!   the result comes back through a tokio oneshot, so async callers never
//!   block a runtime worker and never `dispatch_sync` onto main (which could
//!   deadlock against a main thread waiting on us). Called on the main
//!   thread, the work runs inline. Do not block the main thread on these
//!   futures (`block_on` inside a sync Tauri command): use async commands.
//! - `requestSendPTPCommand` completions arrive on an ImageCaptureCore
//!   queue; results are handed back through a oneshot. Transactions are
//!   serialised by a tokio mutex (one outstanding PTP operation per session).
//! - `ICCameraDevice` objects are messaged from tokio threads, as the iOS
//!   app did from Swift tasks; ImageCaptureCore serialises device requests
//!   internally.

use std::collections::HashMap;
use std::ptr::NonNull;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use block2::RcBlock;
use dispatch2::{DispatchQueue, MainThreadBound};
use objc2::rc::Retained;
use objc2::runtime::{AnyObject, NSObjectProtocol, ProtocolObject};
use objc2::{define_class, msg_send, sel, AnyThread, DefinedClass, MainThreadMarker, Message};
use objc2_core_graphics::CGImage;
use objc2_foundation::{NSArray, NSData, NSDictionary, NSError, NSObject, NSString};
use objc2_image_capture_core::{
    ICCameraDevice, ICCameraDeviceDelegate, ICCameraItem, ICDevice, ICDeviceBrowser,
    ICDeviceBrowserDelegate, ICDeviceDelegate, ICDeviceLocationTypeMask, ICDeviceStatus,
    ICDeviceTypeMask,
};
use tether_types::{CameraVendor, TransportKind};
use tokio::sync::{mpsc, oneshot, Mutex as AsyncMutex};

use super::container::{Grant, PtpUsbContainer, UsbAuthorizationState, UsbCameraCandidate};
use crate::ptp::transport::lock;
use crate::ptp::{
    EventCode, EventStream, PtpError, PtpEvent, PtpRequest, PtpResponse, PtpResult, PtpTransport,
    TransportHealth,
};

/// Console trail for the USB path (filter logs on "[USB]").
const LOG_TARGET: &str = "tether_ptp::usb";

/// How long a session open may take before we tell the user what to do.
const OPEN_TIMEOUT: Duration = Duration::from_secs(15);
/// How long a permission prompt may stay unanswered before we re-read the status.
const AUTHORIZATION_TIMEOUT: Duration = Duration::from_secs(90);
/// Close is best effort; never hang a disconnect on it.
const CLOSE_TIMEOUT: Duration = Duration::from_secs(5);

// MARK: - Main-thread helpers

/// Runs `f` on the main thread and returns its result. Inline when already
/// there; otherwise `dispatch_async` to the main queue. None if the main
/// queue dropped the work (it never runs it when nothing pumps the run loop:
/// then this future simply stays pending).
async fn on_main<R: Send + 'static>(
    f: impl FnOnce(MainThreadMarker) -> R + Send + 'static,
) -> Option<R> {
    if let Some(mtm) = MainThreadMarker::new() {
        return Some(f(mtm));
    }
    let (tx, rx) = oneshot::channel();
    DispatchQueue::main().exec_async(move || {
        // SAFETY: blocks submitted to the main queue run on the main thread.
        let mtm = unsafe { MainThreadMarker::new_unchecked() };
        let _ = tx.send(f(mtm));
    });
    rx.await.ok()
}

/// A retained Objective-C object that may cross threads.
///
/// SAFETY: only used for ImageCaptureCore device objects and our own
/// delegate objects, which the iOS app likewise shared across threads
/// (`@unchecked Sendable`); see the module's threading notes.
struct SendRetained<T: Message>(Retained<T>);
unsafe impl<T: Message> Send for SendRetained<T> {}
unsafe impl<T: Message> Sync for SendRetained<T> {}

/// An ImageCaptureCore camera found by `UsbCameraBrowser`. Cheap to clone.
#[derive(Clone)]
pub struct IccCamera(Arc<SendRetained<ICCameraDevice>>);

impl IccCamera {
    fn new(device: Retained<ICCameraDevice>) -> Self {
        Self(Arc::new(SendRetained(device)))
    }

    fn device(&self) -> &ICCameraDevice {
        &self.0 .0
    }

    pub fn name(&self) -> Option<String> {
        unsafe { self.device().name() }.map(|s| s.to_string())
    }

    pub fn uuid_string(&self) -> Option<String> {
        unsafe { self.device().UUIDString() }.map(|s| s.to_string())
    }

    pub fn has_open_session(&self) -> bool {
        unsafe { self.device().hasOpenSession() }
    }

    fn candidate(&self, id: &str) -> UsbCameraCandidate {
        let d = self.device();
        let serial = unsafe { d.serialNumberString() }.map(|s| s.to_string());
        UsbCameraCandidate::new(
            id,
            self.name().unwrap_or_else(|| "Camera".into()),
            unsafe { d.usbVendorID() },
            unsafe { d.usbProductID() },
            serial,
            self.has_open_session(),
        )
    }

    fn is(&self, other: &ICDevice) -> bool {
        std::ptr::eq(
            (self.device() as *const ICCameraDevice).cast::<u8>(),
            (other as *const ICDevice).cast::<u8>(),
        )
    }
}

impl std::fmt::Debug for IccCamera {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("IccCamera")
            .field("name", &self.name())
            .field("uuid", &self.uuid_string())
            .finish()
    }
}

fn error_text(e: &NSError) -> String {
    e.localizedDescription().to_string()
}

// MARK: - Browser

/// What the browser reports to listeners.
#[derive(Debug, Clone, PartialEq)]
pub enum UsbBrowserEvent {
    Devices(Vec<UsbCameraCandidate>),
    Authorization(UsbAuthorizationState),
    Error(String),
}

/// Fan-out with replay: every listener gets the current camera list and the
/// latest other event on subscribing, then every change.
#[derive(Default)]
struct Broadcaster {
    latest_devices: Vec<UsbCameraCandidate>,
    latest_other: Option<UsbBrowserEvent>,
    listeners: Vec<mpsc::UnboundedSender<UsbBrowserEvent>>,
}

impl Broadcaster {
    fn subscribe(&mut self) -> mpsc::UnboundedReceiver<UsbBrowserEvent> {
        let (tx, rx) = mpsc::unbounded_channel();
        let _ = tx.send(UsbBrowserEvent::Devices(self.latest_devices.clone()));
        if let Some(o) = &self.latest_other {
            let _ = tx.send(o.clone());
        }
        self.listeners.push(tx);
        rx
    }

    fn send(&mut self, event: UsbBrowserEvent) {
        match &event {
            UsbBrowserEvent::Devices(list) => self.latest_devices = list.clone(),
            other => self.latest_other = Some(other.clone()),
        }
        self.listeners.retain(|l| l.send(event.clone()).is_ok());
    }
}

struct BrowserObjects {
    browser: Retained<ICDeviceBrowser>,
    // Kept alive here: the browser does not retain its delegate.
    _delegate: Retained<BrowserDelegate>,
}

struct BrowserShared {
    objects: Mutex<Option<MainThreadBound<BrowserObjects>>>,
    devices: Mutex<HashMap<String, IccCamera>>,
    vendor_filter: Mutex<Option<Vec<CameraVendor>>>,
    authorization: Mutex<UsbAuthorizationState>,
    events: Mutex<Broadcaster>,
}

impl BrowserShared {
    /// Creates the browser and its delegate on first use. Main thread only.
    fn ensure_objects(self: &Arc<Self>, mtm: MainThreadMarker) {
        let mut objects = lock(&self.objects);
        if objects.is_some() {
            return;
        }
        let delegate = BrowserDelegate::new(Arc::downgrade(self));
        let browser = unsafe { ICDeviceBrowser::new() };
        unsafe {
            browser.setDelegate(Some(ProtocolObject::from_ref(&*delegate)));
            // Type AND location: a mask with only the camera bit matches no
            // location, so nothing on the cable is reported.
            browser.setBrowsedDeviceTypeMask(ICDeviceTypeMask(
                ICDeviceTypeMask::Camera.0 | ICDeviceLocationTypeMask::Local.0,
            ));
        }
        *objects = Some(MainThreadBound::new(
            BrowserObjects {
                browser,
                _delegate: delegate,
            },
            mtm,
        ));
    }

    fn with_browser<R>(
        &self,
        mtm: MainThreadMarker,
        f: impl FnOnce(&ICDeviceBrowser) -> R,
    ) -> Option<R> {
        let objects = lock(&self.objects);
        objects.as_ref().map(|o| f(&o.get(mtm).browser))
    }

    /// What the system has on record, without prompting. macOS has no camera
    /// authorizations (the selectors are iOS-only), so both read NotRequired
    /// there; the check is by selector, not by OS.
    fn current_authorization(&self, mtm: MainThreadMarker) -> UsbAuthorizationState {
        self.with_browser(mtm, |b| {
            let mut state = UsbAuthorizationState::new(Grant::NotRequired, Grant::NotRequired);
            if b.respondsToSelector(sel!(contentsAuthorizationStatus)) {
                let s: Retained<NSString> = unsafe { msg_send![b, contentsAuthorizationStatus] };
                state.contents = grant(&s);
            }
            if b.respondsToSelector(sel!(controlAuthorizationStatus)) {
                let s: Retained<NSString> = unsafe { msg_send![b, controlAuthorizationStatus] };
                state.control = grant(&s);
            }
            state
        })
        .unwrap_or_default()
    }

    fn publish(&self) {
        let filter = lock(&self.vendor_filter).clone();
        let (mut list, total) = {
            let devices = lock(&self.devices);
            let list: Vec<UsbCameraCandidate> = devices
                .iter()
                .map(|(id, d)| d.candidate(id))
                .filter(|c| {
                    filter.as_ref().is_none_or(|f| f.contains(&c.vendor_guess))
                        || c.vendor_guess == CameraVendor::Generic
                })
                .collect();
            (list, devices.len())
        };
        tracing::info!(target: LOG_TARGET, "[USB] cameras: {total} seen, {} listed", list.len());
        list.sort_by(|a, b| a.name.cmp(&b.name));
        lock(&self.events).send(UsbBrowserEvent::Devices(list));
    }

    fn did_add(&self, device: &ICDevice, more_coming: bool) {
        let name = unsafe { device.name() }.map(|s| s.to_string());
        tracing::info!(
            target: LOG_TARGET,
            "[USB] didAdd {} usb={:04X}:{:04X} moreComing={more_coming}",
            name.as_deref().unwrap_or("?"),
            unsafe { device.usbVendorID() },
            unsafe { device.usbProductID() },
        );
        let Some(cam) = device.downcast_ref::<ICCameraDevice>() else {
            return;
        };
        let id = unsafe { cam.UUIDString() }
            .map(|s| s.to_string())
            .or(name)
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        lock(&self.devices).insert(id, IccCamera::new(cam.retain()));
        if !more_coming {
            self.publish();
        }
    }

    fn did_remove(&self, device: &ICDevice, more_going: bool) {
        tracing::info!(
            target: LOG_TARGET,
            "[USB] didRemove {}",
            unsafe { device.name() }.map(|s| s.to_string()).unwrap_or_else(|| "?".into())
        );
        lock(&self.devices).retain(|_, d| !d.is(device));
        if !more_going {
            self.publish();
        }
    }
}

/// Maps an ICAuthorizationStatus string. Compared by name rather than via
/// the exported constants, which are not available on macOS.
fn grant(status: &NSString) -> Grant {
    let s = status.to_string();
    if s.contains("Authorized") {
        Grant::Granted
    } else if s.contains("Denied") || s.contains("Restricted") {
        Grant::Denied
    } else {
        Grant::NotDetermined
    }
}

#[derive(Debug, Clone, Copy)]
enum AuthKind {
    Contents,
    Control,
}

struct BrowserIvars {
    shared: Weak<BrowserShared>,
}

define_class!(
    // SAFETY: NSObject has no subclassing requirements; no Drop impl.
    #[unsafe(super(NSObject))]
    #[name = "TetherPtpDeviceBrowserDelegate"]
    #[ivars = BrowserIvars]
    struct BrowserDelegate;

    unsafe impl NSObjectProtocol for BrowserDelegate {}

    unsafe impl ICDeviceBrowserDelegate for BrowserDelegate {
        #[unsafe(method(deviceBrowser:didAddDevice:moreComing:))]
        fn device_browser_did_add(
            &self,
            _browser: &ICDeviceBrowser,
            device: &ICDevice,
            more_coming: bool,
        ) {
            if let Some(s) = self.ivars().shared.upgrade() {
                s.did_add(device, more_coming);
            }
        }

        #[unsafe(method(deviceBrowser:didRemoveDevice:moreGoing:))]
        fn device_browser_did_remove(
            &self,
            _browser: &ICDeviceBrowser,
            device: &ICDevice,
            more_going: bool,
        ) {
            if let Some(s) = self.ivars().shared.upgrade() {
                s.did_remove(device, more_going);
            }
        }

        #[unsafe(method(deviceBrowserDidEnumerateLocalDevices:))]
        fn device_browser_did_enumerate_local_devices(&self, _browser: &ICDeviceBrowser) {
            if let Some(s) = self.ivars().shared.upgrade() {
                s.publish();
            }
        }
    }
);

impl BrowserDelegate {
    fn new(shared: Weak<BrowserShared>) -> Retained<Self> {
        let this = Self::alloc().set_ivars(BrowserIvars { shared });
        unsafe { msg_send![super(this), init] }
    }
}

/// The USB door on macOS: ImageCaptureCore. Discovers cameras with
/// `ICDeviceBrowser`, asks for camera authorizations where the system has
/// them, and hands out `ImageCaptureCoreTransport`s. Capture is never done
/// with `requestTakePicture`; everything goes through raw PTP.
///
/// Cheap to clone; all clones share one browser. See the module docs for the
/// threading model.
#[derive(Clone)]
pub struct UsbCameraBrowser {
    shared: Arc<BrowserShared>,
}

impl Default for UsbCameraBrowser {
    fn default() -> Self {
        Self::new()
    }
}

impl UsbCameraBrowser {
    pub fn new() -> Self {
        Self {
            shared: Arc::new(BrowserShared {
                objects: Mutex::new(None),
                devices: Mutex::new(HashMap::new()),
                vendor_filter: Mutex::new(None),
                authorization: Mutex::new(UsbAuthorizationState::default()),
                events: Mutex::new(Broadcaster::default()),
            }),
        }
    }

    /// Lists only these brands (plus unrecognised USB vendors). None = all.
    pub fn set_vendor_filter(&self, vendors: Option<Vec<CameraVendor>>) {
        *lock(&self.shared.vendor_filter) = vendors;
        self.shared.publish();
    }

    /// Reads the saved permissions, asks only for what is still undecided,
    /// then browses. Where the system reports cameras only once access is
    /// granted, the browser is (re)started after the answers come back.
    pub async fn start(&self) {
        let shared = self.shared.clone();
        let Some(before) = on_main(move |mtm| {
            shared.ensure_objects(mtm);
            shared.current_authorization(mtm)
        })
        .await
        else {
            return;
        };
        let after = self.request_authorizations().await;
        tracing::info!(
            target: LOG_TARGET,
            "[USB] access before: contents={} control={}; after: contents={} control={}",
            before.contents.raw(),
            before.control.raw(),
            after.contents.raw(),
            after.control.raw()
        );
        let shared = self.shared.clone();
        on_main(move |mtm| {
            shared.with_browser(mtm, |b| unsafe {
                if after.can_send_ptp() && !before.can_send_ptp() && b.isBrowsing() {
                    b.stop();
                }
                if !b.isBrowsing() {
                    b.start();
                    tracing::info!(
                        target: LOG_TARGET,
                        "[USB] browser started (mask 0x{:x}), browsing={}",
                        b.browsedDeviceTypeMask().0,
                        b.isBrowsing()
                    );
                }
            });
        })
        .await;
    }

    pub async fn stop(&self) {
        let shared = self.shared.clone();
        on_main(move |mtm| {
            shared.with_browser(mtm, |b| unsafe { b.stop() });
        })
        .await;
    }

    /// A new listener: the current camera list (and latest access state or
    /// error) first, then every change. Every screen that listens gets every
    /// event, so one opened after the camera was plugged in still sees it.
    pub fn events(&self) -> mpsc::UnboundedReceiver<UsbBrowserEvent> {
        lock(&self.shared.events).subscribe()
    }

    /// The last authorization state reported.
    pub fn authorization(&self) -> UsbAuthorizationState {
        *lock(&self.shared.authorization)
    }

    /// What the system has on record, without prompting.
    pub async fn current_authorization(&self) -> UsbAuthorizationState {
        let shared = self.shared.clone();
        on_main(move |mtm| {
            shared.ensure_objects(mtm);
            shared.current_authorization(mtm)
        })
        .await
        .unwrap_or_default()
    }

    /// Ask for contents and control access where the system has no answer
    /// yet, on the main thread (ImageCaptureCore expects it), only where the
    /// request selectors exist. Already-decided permissions are reported as
    /// they are; a denied one can only be changed in System Settings.
    pub async fn request_authorizations(&self) -> UsbAuthorizationState {
        let mut state = self.current_authorization().await;
        if state.contents == Grant::NotDetermined {
            if let Some(g) = self.ask(AuthKind::Contents).await {
                state.contents = g;
            } else {
                state.contents = self.current_authorization().await.contents;
            }
        }
        if state.control == Grant::NotDetermined {
            if let Some(g) = self.ask(AuthKind::Control).await {
                state.control = g;
            } else {
                state.control = self.current_authorization().await.control;
            }
        }
        *lock(&self.shared.authorization) = state;
        lock(&self.shared.events).send(UsbBrowserEvent::Authorization(state));
        state
    }

    /// One permission prompt; None when the selector is missing or the
    /// system never calls back (then the caller re-reads the status instead
    /// of waiting forever).
    async fn ask(&self, kind: AuthKind) -> Option<Grant> {
        let (tx, rx) = oneshot::channel::<Grant>();
        let shared = self.shared.clone();
        let started = on_main(move |mtm| {
            shared
                .with_browser(mtm, |b| {
                    let selector = match kind {
                        AuthKind::Contents => sel!(requestContentsAuthorizationWithCompletion:),
                        AuthKind::Control => sel!(requestControlAuthorizationWithCompletion:),
                    };
                    if !b.respondsToSelector(selector) {
                        return false;
                    }
                    let tx = Mutex::new(Some(tx));
                    let block = RcBlock::new(move |status: NonNull<NSString>| {
                        // SAFETY: ICC passes a valid status string.
                        let g = grant(unsafe { status.as_ref() });
                        if let Some(tx) = lock(&tx).take() {
                            let _ = tx.send(g);
                        }
                    });
                    // SAFETY: both selectors take one completion block with an
                    // ICAuthorizationStatus (NSString) argument; existence checked above.
                    unsafe {
                        match kind {
                            AuthKind::Contents => {
                                let _: () = msg_send![b, requestContentsAuthorizationWithCompletion: &*block];
                            }
                            AuthKind::Control => {
                                let _: () = msg_send![b, requestControlAuthorizationWithCompletion: &*block];
                            }
                        }
                    }
                    true
                })
                .unwrap_or(false)
        })
        .await?;
        if !started {
            return None;
        }
        tokio::time::timeout(AUTHORIZATION_TIMEOUT, rx)
            .await
            .ok()?
            .ok()
    }

    /// One line for the USB screen: is the browser running, what does the
    /// system say about access, and what has it seen on the cable.
    pub async fn status_line(&self) -> String {
        let shared = self.shared.clone();
        on_main(move |mtm| {
            shared.ensure_objects(mtm);
            let auth = shared.current_authorization(mtm);
            shared
                .with_browser(mtm, |b| {
                    let all = unsafe { b.devices() }
                        .map(|a| a.to_vec())
                        .unwrap_or_default();
                    let cams = all
                        .iter()
                        .filter(|d| d.downcast_ref::<ICCameraDevice>().is_some())
                        .count();
                    let browsing = unsafe { b.isBrowsing() };
                    format!(
                        "Browser {} · contents {} · control {} · {} device{} ({} camera{})",
                        if browsing { "on" } else { "off" },
                        auth.contents.raw(),
                        auth.control.raw(),
                        all.len(),
                        if all.len() == 1 { "" } else { "s" },
                        cams,
                        if cams == 1 { "" } else { "s" },
                    )
                })
                .unwrap_or_default()
        })
        .await
        .unwrap_or_default()
    }

    /// The camera with this candidate id, if still attached.
    pub fn device(&self, id: &str) -> Option<IccCamera> {
        lock(&self.shared.devices).get(id).cloned()
    }

    /// The current candidates, unfiltered by listeners.
    pub fn candidates(&self) -> Vec<UsbCameraCandidate> {
        lock(&self.shared.events).latest_devices.clone()
    }

    /// A transport for the camera with this candidate id.
    pub fn transport(&self, id: &str) -> Option<ImageCaptureCoreTransport> {
        self.device(id).map(ImageCaptureCoreTransport::new)
    }
}

// MARK: - Transport

/// Told why the camera went away (cable pulled).
pub type DisconnectHandler = Arc<dyn Fn(String) + Send + Sync>;

struct IccShared {
    session_open: AtomicBool,
    health: Mutex<TransportHealth>,
    events: EventStream,
    on_disconnect: Mutex<Option<DisconnectHandler>>,
}

impl IccShared {
    fn set_last_error(&self, e: impl Into<String>) {
        lock(&self.health).last_error = Some(e.into());
    }
}

struct CameraIvars {
    shared: Arc<IccShared>,
}

define_class!(
    // SAFETY: NSObject has no subclassing requirements; no Drop impl.
    #[unsafe(super(NSObject))]
    #[name = "TetherPtpCameraDeviceDelegate"]
    #[ivars = CameraIvars]
    struct CameraDelegate;

    unsafe impl NSObjectProtocol for CameraDelegate {}

    unsafe impl ICDeviceDelegate for CameraDelegate {
        #[unsafe(method(device:didCloseSessionWithError:))]
        fn device_did_close_session(&self, _device: &ICDevice, _error: Option<&NSError>) {
            self.ivars()
                .shared
                .session_open
                .store(false, Ordering::SeqCst);
        }

        #[unsafe(method(didRemoveDevice:))]
        fn did_remove_device(&self, _device: &ICDevice) {
            let s = &self.ivars().shared;
            s.session_open.store(false, Ordering::SeqCst);
            s.set_last_error("Camera unplugged");
            s.events.push(PtpEvent::new(EventCode::DEVICE_RESET, []));
            let cb = lock(&s.on_disconnect).clone();
            if let Some(cb) = cb {
                cb("The camera was unplugged.".into());
            }
        }

        #[unsafe(method(device:didOpenSessionWithError:))]
        fn device_did_open_session(&self, device: &ICDevice, error: Option<&NSError>) {
            let s = &self.ivars().shared;
            tracing::info!(
                target: LOG_TARGET,
                "[USB] session open on {}: {}",
                unsafe { device.name() }.map(|n| n.to_string()).unwrap_or_else(|| "?".into()),
                error.map(error_text).unwrap_or_else(|| "ok".into())
            );
            s.session_open.store(error.is_none(), Ordering::SeqCst);
            if let Some(e) = error {
                s.set_last_error(error_text(e));
            }
        }

        #[unsafe(method(device:didReceiveStatusInformation:))]
        fn device_did_receive_status(
            &self,
            _device: &ICDevice,
            _status: &NSDictionary<ICDeviceStatus, AnyObject>,
        ) {
        }

        #[unsafe(method(device:didEncounterError:))]
        fn device_did_encounter_error(&self, device: &ICDevice, error: Option<&NSError>) {
            tracing::error!(
                target: LOG_TARGET,
                "[USB] device error on {}: {}",
                unsafe { device.name() }.map(|n| n.to_string()).unwrap_or_else(|| "?".into()),
                error.map(error_text).unwrap_or_else(|| "nil".into())
            );
            if let Some(e) = error {
                self.ivars().shared.set_last_error(error_text(e));
            }
        }
    }

    // Items are handled through raw PTP instead; these exist because the
    // protocol requires them.
    unsafe impl ICCameraDeviceDelegate for CameraDelegate {
        #[unsafe(method(cameraDevice:didAddItems:))]
        fn camera_did_add_items(&self, _camera: &ICCameraDevice, _items: &NSArray<ICCameraItem>) {}

        #[unsafe(method(cameraDevice:didRemoveItems:))]
        fn camera_did_remove_items(
            &self,
            _camera: &ICCameraDevice,
            _items: &NSArray<ICCameraItem>,
        ) {
        }

        #[unsafe(method(cameraDevice:didReceiveThumbnail:forItem:error:))]
        fn camera_did_receive_thumbnail(
            &self,
            _camera: &ICCameraDevice,
            _thumbnail: Option<&CGImage>,
            _item: &ICCameraItem,
            _error: Option<&NSError>,
        ) {
        }

        #[unsafe(method(cameraDevice:didReceiveMetadata:forItem:error:))]
        fn camera_did_receive_metadata(
            &self,
            _camera: &ICCameraDevice,
            _metadata: Option<&NSDictionary>,
            _item: &ICCameraItem,
            _error: Option<&NSError>,
        ) {
        }

        #[unsafe(method(cameraDevice:didRenameItems:))]
        fn camera_did_rename_items(
            &self,
            _camera: &ICCameraDevice,
            _items: &NSArray<ICCameraItem>,
        ) {
        }

        #[unsafe(method(cameraDeviceDidChangeCapability:))]
        fn camera_did_change_capability(&self, _camera: &ICCameraDevice) {}

        #[unsafe(method(cameraDevice:didReceivePTPEvent:))]
        fn camera_did_receive_ptp_event(&self, _camera: &ICCameraDevice, event_data: &NSData) {
            if let Some(ev) = decode_event(&event_data.to_vec()) {
                self.ivars().shared.events.push(ev);
            }
        }

        #[unsafe(method(deviceDidBecomeReadyWithCompleteContentCatalog:))]
        fn device_did_become_ready(&self, _device: &ICCameraDevice) {}

        #[unsafe(method(cameraDeviceDidRemoveAccessRestriction:))]
        fn camera_did_remove_access_restriction(&self, _device: &ICDevice) {}

        #[unsafe(method(cameraDeviceDidEnableAccessRestriction:))]
        fn camera_did_enable_access_restriction(&self, _device: &ICDevice) {}

        #[unsafe(method(cameraDevice:didCompleteDeleteFilesWithError:))]
        fn camera_did_complete_delete(&self, _camera: &ICCameraDevice, _error: Option<&NSError>) {}
    }
);

impl CameraDelegate {
    fn new(shared: Arc<IccShared>) -> Retained<Self> {
        let this = Self::alloc().set_ivars(CameraIvars { shared });
        unsafe { msg_send![super(this), init] }
    }
}

/// A `didReceivePTPEvent` payload (a USB event container) as a PTP event.
pub fn decode_event(event_data: &[u8]) -> Option<PtpEvent> {
    PtpUsbContainer::parse(event_data).ok()?.as_event()
}

/// Builds the response from `requestSendPTPCommand`'s data-in and response
/// container for transaction `tid`.
pub fn decode_response(data_in: Vec<u8>, response: &[u8], tid: u32) -> PtpResult<PtpResponse> {
    let container = PtpUsbContainer::parse(response)?;
    let mut r = container
        .as_response()
        .ok_or_else(|| PtpError::Malformed("ICC returned a non-response container".into()))?;
    r.data_in = data_in;
    r.transaction_id = tid;
    Ok(r)
}

/// Wording for a failed session open.
pub fn describe_open_error(code: isize, description: &str) -> String {
    match code {
        // ICReturnConnectionSessionAlreadyOpen, ICLegacyReturnCodeDeviceAlreadyOpenErr
        -21347 | -9914 => "Another app has this camera open. Close it and try again.".into(),
        _ => format!("Could not open the camera over USB: {description}"),
    }
}

/// `PtpTransport` over an `ICCameraDevice`. Serialises transactions, frames
/// them as USB containers and forwards `didReceivePTPEvent`.
pub struct ImageCaptureCoreTransport {
    camera: IccCamera,
    delegate: SendRetained<CameraDelegate>,
    shared: Arc<IccShared>,
    /// Last transaction ID; the lock serialises transactions.
    serial: AsyncMutex<u32>,
}

impl ImageCaptureCoreTransport {
    /// Becomes the device's delegate (session and PTP-event callbacks).
    pub fn new(camera: IccCamera) -> Self {
        let shared = Arc::new(IccShared {
            session_open: AtomicBool::new(false),
            health: Mutex::new(TransportHealth::default()),
            events: EventStream::default(),
            on_disconnect: Mutex::new(None),
        });
        let delegate = CameraDelegate::new(shared.clone());
        unsafe {
            camera
                .device()
                .setDelegate(Some(ProtocolObject::from_ref(&*delegate)));
        }
        Self {
            camera,
            delegate: SendRetained(delegate),
            shared,
            serial: AsyncMutex::new(0),
        }
    }

    pub fn camera(&self) -> &IccCamera {
        &self.camera
    }

    pub fn health(&self) -> TransportHealth {
        lock(&self.shared.health).clone()
    }

    /// Called when ImageCaptureCore reports the device went away (cable pulled).
    pub fn set_on_disconnect(&self, f: Option<DisconnectHandler>) {
        *lock(&self.shared.on_disconnect) = f;
    }
    /// Starts a session open; the receiver gets the error (code, text), if any.
    /// Sync so no Objective-C value lives across an await.
    fn request_open(&self) -> oneshot::Receiver<Option<(isize, String)>> {
        let (tx, rx) = oneshot::channel();
        let tx = Mutex::new(Some(tx));
        let block = RcBlock::new(move |error: *mut NSError| {
            // SAFETY: ICC passes a valid NSError or nil.
            let e = unsafe { error.as_ref() }.map(|e| (e.code(), error_text(e)));
            if let Some(tx) = lock(&tx).take() {
                let _ = tx.send(e);
            }
        });
        let options = NSDictionary::<NSString, AnyObject>::new();
        unsafe {
            self.camera
                .device()
                .requestOpenSessionWithOptions_completion(Some(&options), &block);
        }
        rx
    }

    fn request_close(&self) -> oneshot::Receiver<()> {
        let (tx, rx) = oneshot::channel();
        let tx = Mutex::new(Some(tx));
        let block = RcBlock::new(move |_error: *mut NSError| {
            if let Some(tx) = lock(&tx).take() {
                let _ = tx.send(());
            }
        });
        unsafe {
            self.camera
                .device()
                .requestCloseSessionWithOptions_completion(None, &block);
        }
        rx
    }

    /// Sends one command container (plus data-out); the receiver gets
    /// (data in, response container). The ICC callback can't be cancelled,
    /// so a timeout just stops waiting; a late completion finds the receiver gone.
    fn send_command(
        &self,
        command: &[u8],
        data_out: Option<&[u8]>,
    ) -> oneshot::Receiver<PtpResult<(Vec<u8>, Vec<u8>)>> {
        let (tx, rx) = oneshot::channel();
        let tx = Mutex::new(Some(tx));
        let block = RcBlock::new(
            move |data_in: NonNull<NSData>, response: NonNull<NSData>, error: *mut NSError| {
                // SAFETY: ICC passes valid NSData objects and a valid NSError or nil.
                let result = match unsafe { error.as_ref() } {
                    Some(e) => Err(PtpError::Malformed(format!("ICC: {}", error_text(e)))),
                    None => Ok(unsafe { (data_in.as_ref().to_vec(), response.as_ref().to_vec()) }),
                };
                if let Some(tx) = lock(&tx).take() {
                    let _ = tx.send(result);
                }
            },
        );
        let command_data = NSData::with_bytes(command);
        let out_data = data_out.map(NSData::with_bytes);
        unsafe {
            self.camera
                .device()
                .requestSendPTPCommand_outData_completion(
                    &command_data,
                    out_data.as_deref(),
                    &block,
                );
        }
        rx
    }
}

impl Drop for ImageCaptureCoreTransport {
    fn drop(&mut self) {
        // The device does not retain its delegate: detach before ours goes.
        let device = self.camera.device();
        let ours: *const CameraDelegate = &*self.delegate.0;
        unsafe {
            if let Some(current) = device.delegate() {
                let current_ptr: *const ProtocolObject<dyn ICDeviceDelegate> = &*current;
                if std::ptr::eq(current_ptr.cast::<u8>(), ours.cast::<u8>()) {
                    device.setDelegate(None);
                }
            }
        }
    }
}

#[async_trait]
impl PtpTransport for ImageCaptureCoreTransport {
    fn kind(&self) -> TransportKind {
        TransportKind::Usb
    }

    fn is_open(&self) -> bool {
        self.shared.session_open.load(Ordering::SeqCst)
    }

    async fn open(&self) -> PtpResult<()> {
        if self.is_open() {
            return Ok(());
        }
        let name = self.camera.name().unwrap_or_else(|| "?".into());
        // Left open by an earlier connection in this process: reuse it.
        if self.camera.has_open_session() {
            tracing::info!(target: LOG_TARGET, "[USB] session already open on {name}; reusing it");
            self.shared.session_open.store(true, Ordering::SeqCst);
            return Ok(());
        }
        // The completion form answers directly (the delegate callback alone
        // could be missed), and a timeout turns a silent stall into a message.
        let rx = self.request_open();
        let result = match tokio::time::timeout(OPEN_TIMEOUT, rx).await {
            Err(_) => Err(PtpError::VendorGate(
                "The camera didn't open a connection. Switch it off and on (or unplug and replug the cable), then connect again."
                    .into(),
            )),
            Ok(Err(_)) => Err(PtpError::TransportClosed),
            Ok(Ok(None)) => Ok(()),
            Ok(Ok(Some((code, text)))) => Err(PtpError::VendorGate(describe_open_error(code, &text))),
        };
        tracing::info!(
            target: LOG_TARGET,
            "[USB] open session: {}",
            result.as_ref().err().map(|e| e.to_string()).unwrap_or_else(|| "ok".into())
        );
        match result {
            Ok(()) => {
                self.shared.session_open.store(true, Ordering::SeqCst);
                Ok(())
            }
            Err(e) => {
                self.shared.set_last_error(e.to_string());
                Err(e)
            }
        }
    }

    async fn close(&self) {
        self.shared.session_open.store(false, Ordering::SeqCst);
        let rx = self.request_close();
        let _ = tokio::time::timeout(CLOSE_TIMEOUT, rx).await;
    }

    async fn execute(&self, request: PtpRequest) -> PtpResult<PtpResponse> {
        let mut serial = self.serial.lock().await;
        if !self.is_open() {
            return Err(PtpError::NotConnected);
        }
        *serial = serial.wrapping_add(1);
        if *serial == 0 {
            *serial = 1;
        }
        let tid = *serial;
        let command = PtpUsbContainer::command(request.code, tid, &request.parameters).encode();
        let started = Instant::now();
        let big = request.expects_large_data;
        if big {
            let params: Vec<String> = request
                .parameters
                .iter()
                .map(|p| format!("{p:x}"))
                .collect();
            tracing::info!(target: LOG_TARGET, "[USB] -> 0x{:x} {}", request.code.0, params.join(","));
        }

        let rx = self.send_command(&command, request.data_out.as_deref());
        let result = match tokio::time::timeout(request.timeout, rx).await {
            Err(_) => Err(PtpError::Timeout { op: request.code }),
            Ok(Err(_)) => Err(PtpError::TransportClosed),
            Ok(Ok(r)) => r.and_then(|(data_in, response)| decode_response(data_in, &response, tid)),
        };
        match &result {
            Ok(r) => {
                {
                    let mut h = lock(&self.shared.health);
                    h.bytes_in += r.data_in.len();
                    h.bytes_out += command.len() + request.data_out.as_ref().map_or(0, Vec::len);
                    h.round_trip_millis = Some(started.elapsed().as_secs_f64() * 1000.0);
                }
                if big {
                    tracing::info!(
                        target: LOG_TARGET,
                        "[USB] <- 0x{:x} {} bytes in {} ms, rc 0x{:x}",
                        request.code.0,
                        r.data_in.len(),
                        started.elapsed().as_millis(),
                        r.code.0
                    );
                }
            }
            Err(e) => {
                tracing::error!(target: LOG_TARGET, "[USB] 0x{:x} failed: {e}", request.code.0);
            }
        }
        result
    }

    fn events(&self) -> EventStream {
        self.shared.events.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ptp::ResponseCode;
    use crate::usb::ContainerType;

    #[test]
    fn decodes_icc_response_and_event_payloads() {
        let resp =
            PtpUsbContainer::new(ContainerType::Response, 0x2019, 4, vec![1, 0, 0, 0]).encode();
        let r = decode_response(vec![9, 9], &resp, 42).unwrap();
        assert_eq!(r.code, ResponseCode::DEVICE_BUSY);
        assert_eq!(r.parameters, vec![1]);
        assert_eq!(r.data_in, vec![9, 9]);
        assert_eq!(r.transaction_id, 42);

        let data = PtpUsbContainer::new(ContainerType::Data, 0x1009, 4, vec![]).encode();
        assert!(matches!(
            decode_response(vec![], &data, 1),
            Err(PtpError::Malformed(_))
        ));
        assert!(decode_response(vec![], &[0, 1], 1).is_err());

        let ev = PtpUsbContainer::new(ContainerType::Event, 0x400D, 0, vec![]).encode();
        assert_eq!(
            decode_event(&ev).map(|e| e.code),
            Some(EventCode::CAPTURE_COMPLETE)
        );
        assert!(decode_event(&resp).is_none());
        assert!(decode_event(&[1, 2, 3]).is_none());
    }

    #[test]
    fn delegate_classes_register_and_forward_ptp_events() {
        let shared = Arc::new(IccShared {
            session_open: AtomicBool::new(false),
            health: Mutex::new(TransportHealth::default()),
            events: EventStream::default(),
            on_disconnect: Mutex::new(None),
        });
        let delegate = CameraDelegate::new(shared.clone());
        assert!(delegate.respondsToSelector(sel!(cameraDevice:didReceivePTPEvent:)));
        assert!(delegate.respondsToSelector(sel!(didRemoveDevice:)));
        let _proto: &ProtocolObject<dyn ICCameraDeviceDelegate> =
            ProtocolObject::from_ref(&*delegate);

        // Drive the callbacks the way ImageCaptureCore would.
        let camera = unsafe { ICCameraDevice::new() };
        let ev =
            PtpUsbContainer::new(ContainerType::Event, 0x4002, 0, vec![0x42, 0, 0, 0]).encode();
        let data = NSData::with_bytes(&ev);
        unsafe {
            let _: () = msg_send![&*delegate, cameraDevice: &*camera, didReceivePTPEvent: &*data];
            let _: () = msg_send![&*delegate, device: &*camera, didOpenSessionWithError: std::ptr::null::<NSError>()];
        }
        let got = shared.events.try_next().expect("event forwarded");
        assert_eq!(got.code, EventCode::OBJECT_ADDED);
        assert_eq!(got.parameters, vec![0x42]);
        assert!(shared.session_open.load(Ordering::SeqCst));
        unsafe {
            let _: () = msg_send![&*delegate, didRemoveDevice: &*camera];
        }
        assert!(!shared.session_open.load(Ordering::SeqCst));
        assert_eq!(
            shared.events.try_next().map(|e| e.code),
            Some(EventCode::DEVICE_RESET)
        );

        let browser_delegate = BrowserDelegate::new(Weak::new());
        assert!(browser_delegate.respondsToSelector(sel!(deviceBrowser:didAddDevice:moreComing:)));
    }

    #[test]
    fn open_error_wording() {
        assert!(describe_open_error(-21347, "x").starts_with("Another app"));
        assert!(describe_open_error(-9914, "x").starts_with("Another app"));
        assert_eq!(
            describe_open_error(-1, "Boom"),
            "Could not open the camera over USB: Boom"
        );
    }

    #[test]
    fn broadcaster_replays_latest() {
        let mut b = Broadcaster::default();
        b.send(UsbBrowserEvent::Error("x".into()));
        let mut rx = b.subscribe();
        assert_eq!(rx.try_recv().unwrap(), UsbBrowserEvent::Devices(vec![]));
        assert_eq!(rx.try_recv().unwrap(), UsbBrowserEvent::Error("x".into()));
        b.send(UsbBrowserEvent::Devices(vec![]));
        assert!(rx.try_recv().is_ok());
    }

    #[test]
    fn authorization_status_names() {
        assert_eq!(
            grant(&NSString::from_str("ICAuthorizationStatusAuthorized")),
            Grant::Granted
        );
        assert_eq!(
            grant(&NSString::from_str("ICAuthorizationStatusRestricted")),
            Grant::Denied
        );
        assert_eq!(
            grant(&NSString::from_str("ICAuthorizationStatusNotDetermined")),
            Grant::NotDetermined
        );
    }
}
