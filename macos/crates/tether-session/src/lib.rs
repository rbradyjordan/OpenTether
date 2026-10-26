//! tether-session: the live tether session, diagnostics, and the
//! [`AppCore`] facade the Tauri shell calls.
//!
//! Ported from the iOS package `TetherCore` (`Capture/TetherSession.swift`,
//! `ReconnectPolicy.swift`, `CaptureCacheProxy.swift`, `Diagnostics/`) and
//! the app layer that orchestrates them (`Tether/App`, `Connect`, `Shoot`,
//! `Library`, `Commands`, `Adapters`).
//!
//! - [`session`]: [`TetherSession`] (connect, event loop, download → store →
//!   previews, capture / AF / live view / properties, FTP and file ingest),
//!   reconnect policy and strategy, and the connection builder.
//! - [`cache`]: [`CaptureCacheProxy`], the capture file store.
//! - [`diagnostics`]: the wired and wireless checklists.
//! - [`app_core`]: [`AppCore`], one object owning everything the UI needs,
//!   with one broadcast of [`AppEvent`]s.

pub mod app_core;
pub mod cache;
pub mod demo;
pub mod diagnostics;
mod error;
pub mod events;
pub mod platform;
pub mod session;
pub mod settings;
pub mod sinks;

pub use app_core::{AppCore, AppCoreConfig, ImageKind};
pub use cache::CaptureCacheProxy;
pub use error::{ConnectError, Error, Result};
pub use events::AppEvent;
pub use session::{
    LiveConnection, ReconnectContext, ReconnectPolicy, ReconnectStrategy, SessionEvent, Snapshot,
    TetherSession, TetherStatus,
};
