//! The live shoot (`TetherCore/Capture/`): [`TetherSession`], reconnect
//! policy and strategy, and the connection builder.

pub mod connect;
pub mod reconnect;
pub mod tether_session;

pub use connect::{ConnectProgress, ConnectServices, ConnectStep, LiveConnection};
pub use reconnect::{PolicyStrategy, ReconnectContext, ReconnectPolicy, ReconnectStrategy};
pub use tether_session::{
    library_kind, SessionEvent, Snapshot, TetherSession, TetherStatus, WeakTetherSession,
};
