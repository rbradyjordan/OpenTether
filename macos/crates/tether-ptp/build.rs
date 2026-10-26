//! Links ImageCaptureCore for the macOS USB transport (the bindings crate
//! also requests it; this keeps the dependency explicit).
fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-link-lib=framework=ImageCaptureCore");
    }
    println!("cargo:rerun-if-changed=build.rs");
}
