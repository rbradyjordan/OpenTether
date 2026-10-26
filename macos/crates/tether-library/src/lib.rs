//! tether-library: everything that happens to a frame after it lands.
//!
//! Ported from the iOS package `TetherCore` (`Capture/CaptureItem.swift`,
//! `Store/`, `Library/`, `Looks/`, `Interop/`, `Delivery/`) plus the app's
//! ImageIO preview generator. The SQLite schema, the JSON stored in it, the
//! `.cube` files and the XMP sidecars are the same as on iOS, so a library
//! (or a sidecar) written by one app opens in the other.
//!
//! - [`capture_item`]: the data model (captures, sessions, routing).
//! - [`store`]: [`SessionStore`], the SQLite recovery journal and library index.
//! - [`library`]: collections and filters, the review editor with undo,
//!   the command catalogue, session automations and workspace memory.
//! - [`looks`]: `.cube` LUTs, built-in looks, colour match and a CPU renderer.
//! - [`interop`]: XMP, EXIF, naming templates and folder layouts, file
//!   import plans, Lightroom / Capture One catalog read-back.
//! - [`delivery`]: export jobs and the resumable export queue.
//! - [`previews`]: proxy and thumbnail JPEGs for new captures.
//! - [`imaging`]: decoding (Core Image RAW development on macOS), resizing, encoding.
//!
//! The store is synchronous and thread-safe (one connection behind a mutex);
//! async callers should wrap heavy calls in `spawn_blocking`.

pub mod capture_item;
pub mod delivery;
mod error;
pub mod imaging;
pub mod interop;
pub mod library;
pub mod looks;
pub mod previews;
pub mod store;
mod swift_json;
mod util;

pub use capture_item::{
    CaptureFlag, CaptureItem, CaptureState, ColorLabel, ExposureSummary, MediaKind, RoutingRules,
    RoutingTarget, SessionStatus, ShootSession,
};
pub use error::{Error, Result};
pub use store::SessionStore;
