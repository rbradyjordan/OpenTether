//! Core Image on macOS: full RAW development (`CIRAWFilter`, the system RAW
//! engine with the camera's as-shot white balance and lens profile), HEIF
//! decoding, and HEIF encoding. Everything else in the library is CPU code;
//! this is the one place that talks to Apple frameworks.

use std::ffi::c_void;
use std::ptr::NonNull;

use objc2::rc::{autoreleasepool, Retained};
use objc2::runtime::AnyObject;
use objc2_core_foundation::{CFRetained, CGAffineTransform, CGPoint, CGRect, CGSize};
use objc2_core_graphics::{kCGColorSpaceSRGB, CGColorSpace};
use objc2_core_image::{kCIFormatRGBA16, kCIFormatRGBA8, CIContext, CIImage, CIRAWFilter};
use objc2_foundation::{NSData, NSDictionary, NSNumber, NSString};

/// A rendered image: 16-bit RGBA, sRGB, unpremultiplied for opaque content.
pub struct Bitmap16 {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u16>,
}

fn srgb() -> Option<CFRetained<CGColorSpace>> {
    // SAFETY: reading an immutable framework constant.
    CGColorSpace::with_name(Some(unsafe { kCGColorSpaceSRGB }))
}

/// UTI for a RAW extension, as `UTType(filenameExtension:)` would give.
fn raw_uti(ext: &str) -> Option<&'static str> {
    Some(match ext.to_lowercase().as_str() {
        "cr2" => "com.canon.cr2-raw-image",
        "cr3" => "com.canon.cr3-raw-image",
        "crw" => "com.canon.crw-raw-image",
        "nef" => "com.nikon.raw-image",
        "nrw" => "com.nikon.nrw-raw-image",
        "arw" => "com.sony.arw-raw-image",
        "sr2" => "com.sony.sr2-raw-image",
        "raf" => "com.fuji.raw-image",
        "orf" => "com.olympus.raw-image",
        "rw2" => "com.panasonic.rw2-raw-image",
        "rwl" => "com.leica.rwl-raw-image",
        "dng" => "com.adobe.raw-image",
        "pef" => "com.pentax.raw-image",
        "srw" => "com.samsung.raw-image",
        "3fr" | "fff" => "com.hasselblad.3fr-raw-image",
        "x3f" => "com.sigma.raw-image",
        "iiq" => "com.phaseone.raw-image",
        "erf" => "com.epson.raw-image",
        "mos" => "com.leafamerica.raw-image",
        "mrw" => "com.konicaminolta.raw-image",
        "kdc" | "dcr" => "com.kodak.raw-image",
        _ => return None,
    })
}

fn ci_image(
    data: &[u8],
    raw_extension: Option<&str>,
    orientation: u8,
) -> Option<Retained<CIImage>> {
    let ns = NSData::with_bytes(data);
    // SAFETY: plain Core Image constructors on valid objects.
    unsafe {
        if let Some(ext) = raw_extension {
            let hint = raw_uti(ext).map(NSString::from_str);
            if let Some(filter) =
                CIRAWFilter::filterWithImageData_identifierHint(&ns, hint.as_deref())
            {
                if let Some(out) = filter.outputImage() {
                    return Some(out);
                }
            }
            // Not something the RAW engine reads: let the caller fall back
            // to the embedded preview rather than guessing.
            return None;
        }
        let image = CIImage::imageWithData(&ns)?;
        Some(if (2..=8).contains(&orientation) {
            image.imageByApplyingOrientation(orientation as i32)
        } else {
            image
        })
    }
}

/// Upright pixel size of an image (RAW: as developed) without rendering it.
pub fn extent(data: &[u8], raw_extension: Option<&str>, orientation: u8) -> Option<(u32, u32)> {
    autoreleasepool(|_| {
        let image = ci_image(data, raw_extension, orientation)?;
        // SAFETY: reading the extent of a valid image.
        let e = unsafe { image.extent() };
        let (w, h) = (e.size.width.round(), e.size.height.round());
        (w.is_finite() && h.is_finite() && w >= 1.0 && h >= 1.0 && w < 1e6 && h < 1e6)
            .then_some((w as u32, h as u32))
    })
}

/// Decodes (and for RAW, develops) an image with Core Image, scaled so the
/// long edge is at most `max_long_edge`. `raw_extension` selects the RAW
/// engine; `orientation` (EXIF 1…8) is applied to non-RAW input.
pub fn decode(
    data: &[u8],
    raw_extension: Option<&str>,
    orientation: u8,
    max_long_edge: Option<u32>,
) -> Option<Bitmap16> {
    autoreleasepool(|_| {
        let mut image = ci_image(data, raw_extension, orientation)?;
        // SAFETY: Core Image calls on valid objects; the bitmap buffer is
        // sized for exactly `bounds` at 8 bytes per pixel.
        unsafe {
            let extent = image.extent();
            let long = extent.size.width.max(extent.size.height);
            if let Some(max) = max_long_edge.filter(|m| *m > 0 && long > f64::from(*m)) {
                let s = f64::from(max) / long;
                let t = CGAffineTransform {
                    a: s,
                    b: 0.0,
                    c: 0.0,
                    d: s,
                    tx: 0.0,
                    ty: 0.0,
                };
                image = image.imageByApplyingTransform_highQualityDownsample(t, true);
            }
            let e = image.extent();
            if !e.size.width.is_finite() || !e.size.height.is_finite() {
                return None;
            }
            let x = e.origin.x.floor();
            let y = e.origin.y.floor();
            let w = ((e.origin.x + e.size.width).ceil() - x).max(1.0) as usize;
            let h = ((e.origin.y + e.size.height).ceil() - y).max(1.0) as usize;
            if w > 30_000 || h > 30_000 {
                return None;
            }
            let bounds = CGRect {
                origin: CGPoint { x, y },
                size: CGSize {
                    width: w as f64,
                    height: h as f64,
                },
            };
            let mut buf = vec![0u16; w * h * 4];
            let context = CIContext::contextWithOptions(None);
            let space = srgb()?;
            context.render_toBitmap_rowBytes_bounds_format_colorSpace(
                &image,
                NonNull::new(buf.as_mut_ptr() as *mut c_void)?,
                (w * 8) as isize,
                bounds,
                kCIFormatRGBA16,
                Some(&space),
            );
            Some(Bitmap16 {
                width: w as u32,
                height: h as u32,
                rgba: buf,
            })
        }
    })
}

/// Encodes 16-bit RGB pixels as HEIF (8-bit, sRGB) with Core Image.
pub fn encode_heif(width: u32, height: u32, rgb16: &[u16], quality: f64) -> Option<Vec<u8>> {
    let (w, h) = (width as usize, height as usize);
    if rgb16.len() != w * h * 3 {
        return None;
    }
    let mut rgba: Vec<u8> = Vec::with_capacity(w * h * 8);
    for px in rgb16.as_chunks::<3>().0 {
        for v in [px[0], px[1], px[2], u16::MAX] {
            rgba.extend_from_slice(&v.to_ne_bytes());
        }
    }
    autoreleasepool(|_| {
        let data = NSData::with_bytes(&rgba);
        let space = srgb()?;
        // SAFETY: the NSData holds exactly w×h RGBA16 pixels.
        unsafe {
            let image = CIImage::imageWithBitmapData_bytesPerRow_size_format_colorSpace(
                &data,
                w * 8,
                CGSize {
                    width: w as f64,
                    height: h as f64,
                },
                kCIFormatRGBA16,
                Some(&space),
            );
            let context = CIContext::contextWithOptions(None);
            // The ImageIO key's value is its own name.
            let key = NSString::from_str("kCGImageDestinationLossyCompressionQuality");
            let number = NSNumber::new_f64(quality.clamp(0.3, 1.0));
            let value: &AnyObject = &number;
            let options = NSDictionary::<NSString, AnyObject>::from_slices(&[&*key], &[value]);
            let out = context.HEIFRepresentationOfImage_format_colorSpace_options(
                &image,
                kCIFormatRGBA8,
                &space,
                &options,
            )?;
            Some(out.to_vec())
        }
    })
}
