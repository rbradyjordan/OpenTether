//! The command catalogue (`Commands` in `Library/ReviewEditor.swift`).
//!
//! The one place every menu, context menu, keyboard shortcut and command
//! palette entry comes from. Views ask [`Commands::available`] and render;
//! they never hardcode action lists, so adding a workflow is adding a command.

use serde::Serialize;
use tether_types::CameraCapabilities;

use crate::library::{Collection, CollectionKind};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum CommandGroup {
    Review,
    Organize,
    Export,
    Session,
    View,
    Camera,
}

impl CommandGroup {
    pub fn raw(self) -> &'static str {
        match self {
            Self::Review => "review",
            Self::Organize => "organize",
            Self::Export => "export",
            Self::Session => "session",
            Self::View => "view",
            Self::Camera => "camera",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Command {
    pub id: &'static str,
    pub title: &'static str,
    /// SF Symbol name (the UI maps it to its own icon set).
    pub symbol: &'static str,
    pub group: CommandGroup,
    /// Display hint, e.g. "1"…"5", "P", "X", "⌘E".
    pub shortcut: Option<&'static str>,
    pub is_destructive: bool,
}

const fn cmd(
    id: &'static str,
    title: &'static str,
    symbol: &'static str,
    group: CommandGroup,
    shortcut: Option<&'static str>,
) -> Command {
    Command {
        id,
        title,
        symbol,
        group,
        shortcut,
        is_destructive: false,
    }
}

/// What the UI knows when it asks which commands apply.
#[derive(Debug, Clone, Default)]
pub struct CommandContext {
    pub selection_count: usize,
    pub in_live_session: bool,
    pub camera_capabilities: CameraCapabilities,
    pub in_collection: Option<Collection>,
    pub can_undo: bool,
    pub can_redo: bool,
}

/// The catalogue.
pub struct Commands;

use CommandGroup as G;

impl Commands {
    pub const RATE0: Command = cmd("rate.0", "Clear rating", "star.slash", G::Review, Some("0"));
    pub const RATE: [Command; 5] = [
        cmd("rate.1", "Rate 1 star", "star.fill", G::Review, Some("1")),
        cmd("rate.2", "Rate 2 stars", "star.fill", G::Review, Some("2")),
        cmd("rate.3", "Rate 3 stars", "star.fill", G::Review, Some("3")),
        cmd("rate.4", "Rate 4 stars", "star.fill", G::Review, Some("4")),
        cmd("rate.5", "Rate 5 stars", "star.fill", G::Review, Some("5")),
    ];
    pub const PICK: Command = cmd("flag.pick", "Pick", "flag.fill", G::Review, Some("P"));
    pub const REJECT: Command = cmd("flag.reject", "Reject", "xmark", G::Review, Some("X"));
    pub const UNFLAG: Command = cmd("flag.none", "Unflag", "flag.slash", G::Review, Some("U"));
    pub const LABELS: [Command; 5] = [
        cmd("label.red", "Label red", "circle.fill", G::Review, None),
        cmd(
            "label.yellow",
            "Label yellow",
            "circle.fill",
            G::Review,
            None,
        ),
        cmd("label.green", "Label green", "circle.fill", G::Review, None),
        cmd("label.blue", "Label blue", "circle.fill", G::Review, None),
        cmd(
            "label.purple",
            "Label purple",
            "circle.fill",
            G::Review,
            None,
        ),
    ];
    pub const CLEAR_LABEL: Command = cmd("label.none", "Clear label", "circle", G::Review, None);
    pub const TAG: Command = cmd("tag.add", "Add tags…", "number", G::Organize, Some("T"));
    pub const ADD_TO_COLLECTION: Command = cmd(
        "collection.add",
        "Add to collection…",
        "rectangle.stack.badge.plus",
        G::Organize,
        Some("⇧⌘K"),
    );
    pub const NEW_COLLECTION: Command = cmd(
        "collection.new",
        "New collection from selection",
        "plus.rectangle.on.rectangle",
        G::Organize,
        None,
    );
    pub const REMOVE_FROM_COLLECTION: Command = cmd(
        "collection.remove",
        "Remove from this collection",
        "rectangle.stack.badge.minus",
        G::Organize,
        Some("⌫"),
    );
    pub const SAVE_SMART: Command = cmd(
        "collection.smart",
        "Save filter as smart collection",
        "sparkles.rectangle.stack",
        G::Organize,
        None,
    );
    pub const EXPORT: Command = cmd(
        "export",
        "Export…",
        "square.and.arrow.up",
        G::Export,
        Some("⌘E"),
    );
    pub const EXPORT_AGAIN: Command = cmd(
        "export.again",
        "Export like last time",
        "arrow.uturn.up",
        G::Export,
        Some("⇧⌘E"),
    );
    pub const COLOR_MATCH: Command = cmd(
        "look.match",
        "Match colour to this frame…",
        "wand.and.stars",
        G::Export,
        None,
    );
    pub const COMPARE: Command = cmd(
        "view.compare",
        "Compare",
        "rectangle.split.2x1",
        G::View,
        Some("C"),
    );
    pub const CLIENT_REVIEW: Command = cmd(
        "view.client",
        "Client review",
        "rectangle.inset.filled",
        G::View,
        Some("⇧R"),
    );
    pub const SELECT_ALL: Command = cmd(
        "select.all",
        "Select all",
        "checkmark.circle",
        G::View,
        Some("⌘A"),
    );
    pub const SELECT_PICKS: Command = cmd("select.picks", "Select picks", "flag", G::View, None);
    pub const INVERT: Command = cmd(
        "select.invert",
        "Invert selection",
        "arrow.triangle.2.circlepath",
        G::View,
        None,
    );
    pub const UNDO: Command = cmd(
        "undo",
        "Undo",
        "arrow.uturn.backward",
        G::Review,
        Some("⌘Z"),
    );
    pub const REDO: Command = cmd(
        "redo",
        "Redo",
        "arrow.uturn.forward",
        G::Review,
        Some("⇧⌘Z"),
    );
    pub const CAPTURE: Command = cmd(
        "camera.capture",
        "Capture",
        "circle.inset.filled",
        G::Camera,
        Some("Space"),
    );
    pub const LIVE_VIEW: Command = cmd("camera.liveview", "Live view", "eye", G::Camera, Some("L"));
    pub const DELETE: Command = Command {
        id: "delete",
        title: "Delete from this Mac",
        symbol: "trash",
        group: G::Organize,
        shortcut: None,
        is_destructive: true,
    };
    pub const SAVE_TEMPLATE: Command = cmd(
        "session.template",
        "Save session as template",
        "doc.badge.plus",
        G::Session,
        None,
    );
    pub const END_SESSION: Command = cmd(
        "session.end",
        "End session",
        "stop.circle",
        G::Session,
        None,
    );

    /// Every command, for lookups by id.
    pub fn all() -> Vec<Command> {
        let mut out = vec![Self::CAPTURE, Self::LIVE_VIEW];
        out.extend(Self::RATE);
        out.extend([Self::RATE0, Self::PICK, Self::REJECT, Self::UNFLAG]);
        out.extend(Self::LABELS);
        out.extend([
            Self::CLEAR_LABEL,
            Self::TAG,
            Self::ADD_TO_COLLECTION,
            Self::NEW_COLLECTION,
            Self::REMOVE_FROM_COLLECTION,
            Self::EXPORT,
            Self::EXPORT_AGAIN,
            Self::COLOR_MATCH,
            Self::COMPARE,
            Self::CLIENT_REVIEW,
            Self::SELECT_ALL,
            Self::SELECT_PICKS,
            Self::INVERT,
            Self::SAVE_SMART,
            Self::UNDO,
            Self::REDO,
            Self::SAVE_TEMPLATE,
            Self::END_SESSION,
            Self::DELETE,
        ]);
        out
    }

    pub fn by_id(id: &str) -> Option<Command> {
        Self::all().into_iter().find(|c| c.id == id)
    }

    /// Commands that make sense right now, grouped and ordered for a menu.
    pub fn available(ctx: &CommandContext) -> Vec<Command> {
        let mut out = Vec::new();
        let sel = ctx.selection_count > 0;
        if ctx.in_live_session {
            if ctx
                .camera_capabilities
                .contains(CameraCapabilities::REMOTE_CAPTURE)
            {
                out.push(Self::CAPTURE);
            }
            if ctx
                .camera_capabilities
                .contains(CameraCapabilities::LIVE_VIEW)
            {
                out.push(Self::LIVE_VIEW);
            }
        }
        if sel {
            out.extend(Self::RATE);
            out.extend([Self::RATE0, Self::PICK, Self::REJECT, Self::UNFLAG]);
            out.extend(Self::LABELS);
            out.extend([
                Self::CLEAR_LABEL,
                Self::TAG,
                Self::ADD_TO_COLLECTION,
                Self::NEW_COLLECTION,
            ]);
            if ctx
                .in_collection
                .as_ref()
                .is_some_and(|c| c.kind == CollectionKind::Manual)
            {
                out.push(Self::REMOVE_FROM_COLLECTION);
            }
            out.extend([Self::EXPORT, Self::EXPORT_AGAIN]);
            if ctx.selection_count == 1 {
                out.push(Self::COLOR_MATCH);
            }
            if ctx.selection_count == 2 {
                out.push(Self::COMPARE);
            }
            out.push(Self::CLIENT_REVIEW);
        }
        out.extend([Self::SELECT_ALL, Self::SELECT_PICKS]);
        if sel {
            out.push(Self::INVERT);
        }
        if ctx
            .in_collection
            .as_ref()
            .is_some_and(|c| c.kind == CollectionKind::Smart && !c.is_built_in)
        {
            out.push(Self::SAVE_SMART);
        }
        if ctx.can_undo {
            out.push(Self::UNDO);
        }
        if ctx.can_redo {
            out.push(Self::REDO);
        }
        if ctx.in_live_session {
            out.extend([Self::SAVE_TEMPLATE, Self::END_SESSION]);
        }
        if sel {
            out.push(Self::DELETE);
        }
        out
    }

    /// Full-text match for the command palette: title, group, shortcut.
    pub fn search(query: &str, ctx: &CommandContext) -> Vec<Command> {
        let q = query.trim_matches([' ', '\t']).to_lowercase();
        let all = Self::available(ctx);
        if q.is_empty() {
            return all;
        }
        let mut hits: Vec<Command> = all
            .into_iter()
            .filter(|c| {
                c.title.to_lowercase().contains(&q)
                    || c.group.raw().contains(&q)
                    || c.shortcut.map(|s| s.to_lowercase()) == Some(q.clone())
            })
            .collect();
        hits.sort_by_key(|c| !c.title.to_lowercase().starts_with(&q));
        hits
    }
}
