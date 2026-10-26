//! The library (`Library/`): collections and filters, the review editor with
//! undo/redo, the command catalogue, session automations and workspace memory.

pub mod automations;
pub mod collection;
pub mod commands;
pub mod editor;
pub mod memory;

pub use automations::{AutomationEvent, AutomationRules, SessionAutomations};
pub use collection::{
    CaptureFilter, CaptureSort, CaptureStack, Collection, CollectionKind, DateRange,
    ExportDestinationKey,
};
pub use commands::{Command, CommandContext, CommandGroup, Commands};
pub use editor::{EditorEvent, LiveCaptureHook, ReviewChange, ReviewEdit, ReviewEditor, Selection};
pub use memory::WorkspaceMemory;

/// Refusals the library reports to the user as they are.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum LibraryError {
    #[error("Built-in collections can't be changed.")]
    BuiltInCollection,
    #[error("Only your own collections take hand-picked photos; this one is a smart collection.")]
    NotManual,
    #[error("Nothing is selected.")]
    NothingSelected,
}
