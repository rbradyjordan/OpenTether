//! Saving exports to the Photos library (`PhotosExportSink.swift`) through
//! PhotoKit. Only add-only access is ever requested.

use std::path::Path;

/// The Photos library as the export sink sees it.
#[async_trait::async_trait]
pub trait PhotoLibrary: Send + Sync {
    /// Ask for add-only access if undecided; true when adding is allowed.
    async fn request_add_only(&self) -> bool;
    /// Adds an image file; returns the new asset's local identifier.
    async fn add_image(&self, file: &Path) -> Result<Option<String>, String>;
}

/// The user's Photos library (PhotoKit on macOS).
#[derive(Debug, Default, Clone, Copy)]
pub struct SystemPhotoLibrary;

pub const NOT_AUTHORIZED: &str = "Open Tether is not allowed to add to your photo library. Enable it in System Settings → Privacy & Security → Photos.";

#[cfg(target_os = "macos")]
mod imp {
    use std::path::Path;
    use std::sync::{Arc, Mutex};

    use block2::RcBlock;
    use objc2_foundation::{NSString, NSURL};
    use objc2_photos::{
        PHAccessLevel, PHAssetChangeRequest, PHAuthorizationStatus, PHPhotoLibrary,
    };

    fn allowed(s: PHAuthorizationStatus) -> bool {
        s == PHAuthorizationStatus::Authorized || s == PHAuthorizationStatus::Limited
    }

    /// Add-only access as the system has it on record (no prompt):
    /// `Some(true)` allowed, `Some(false)` denied, `None` undecided.
    pub fn add_only_status() -> Option<bool> {
        let status =
            unsafe { PHPhotoLibrary::authorizationStatusForAccessLevel(PHAccessLevel::AddOnly) };
        (status != PHAuthorizationStatus::NotDetermined).then(|| allowed(status))
    }

    pub async fn request_add_only() -> bool {
        let status =
            unsafe { PHPhotoLibrary::authorizationStatusForAccessLevel(PHAccessLevel::AddOnly) };
        if status != PHAuthorizationStatus::NotDetermined {
            return allowed(status);
        }
        let rx = ask();
        rx.await.map(allowed).unwrap_or(false)
    }

    fn ask() -> tokio::sync::oneshot::Receiver<PHAuthorizationStatus> {
        let (tx, rx) = tokio::sync::oneshot::channel::<PHAuthorizationStatus>();
        let tx = Mutex::new(Some(tx));
        let handler = RcBlock::new(move |s: PHAuthorizationStatus| {
            if let Some(tx) = tx.lock().unwrap_or_else(|e| e.into_inner()).take() {
                let _ = tx.send(s);
            }
        });
        unsafe {
            PHPhotoLibrary::requestAuthorizationForAccessLevel_handler(
                PHAccessLevel::AddOnly,
                &handler,
            )
        };
        rx
    }

    pub fn add_image_blocking(file: &Path) -> Result<Option<String>, String> {
        let path = NSString::from_str(&file.to_string_lossy());
        let url = NSURL::fileURLWithPath(&path);
        let local_id: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
        let out = local_id.clone();
        let change = RcBlock::new(move || {
            let request =
                unsafe { PHAssetChangeRequest::creationRequestForAssetFromImageAtFileURL(&url) };
            if let Some(r) = request {
                if let Some(p) = unsafe { r.placeholderForCreatedAsset() } {
                    let id = unsafe { p.localIdentifier() }.to_string();
                    *out.lock().unwrap_or_else(|e| e.into_inner()) = Some(id);
                }
            }
        });
        let library = unsafe { PHPhotoLibrary::sharedPhotoLibrary() };
        let block: &block2::DynBlock<dyn Fn()> = &change;
        unsafe {
            library.performChangesAndWait_error(
                block as *const block2::DynBlock<dyn Fn()> as *mut block2::DynBlock<dyn Fn()>,
            )
        }
        .map_err(|e| e.localizedDescription().to_string())?;
        let id = local_id.lock().unwrap_or_else(|e| e.into_inner()).clone();
        Ok(id)
    }
}

impl SystemPhotoLibrary {
    /// Add-only access without prompting: `Some(true)` allowed,
    /// `Some(false)` denied, `None` not asked yet.
    #[cfg(target_os = "macos")]
    pub fn add_only_status() -> Option<bool> {
        imp::add_only_status()
    }

    #[cfg(not(target_os = "macos"))]
    pub fn add_only_status() -> Option<bool> {
        Some(false)
    }
}

#[async_trait::async_trait]
impl PhotoLibrary for SystemPhotoLibrary {
    #[cfg(target_os = "macos")]
    async fn request_add_only(&self) -> bool {
        imp::request_add_only().await
    }

    #[cfg(not(target_os = "macos"))]
    async fn request_add_only(&self) -> bool {
        false
    }

    #[cfg(target_os = "macos")]
    async fn add_image(&self, file: &Path) -> Result<Option<String>, String> {
        let file = file.to_path_buf();
        tokio::task::spawn_blocking(move || imp::add_image_blocking(&file))
            .await
            .map_err(|e| e.to_string())?
    }

    #[cfg(not(target_os = "macos"))]
    async fn add_image(&self, _file: &Path) -> Result<Option<String>, String> {
        Err("Photos is only available on macOS.".into())
    }
}
