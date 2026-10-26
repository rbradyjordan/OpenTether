//! The one seam between the PTP engine and the wire.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use tether_types::TransportKind;
use tokio::sync::Notify;

use super::transaction::{PtpEvent, PtpRequest, PtpResponse, PtpResult};

/// The one seam between the PTP engine and the wire. ImageCaptureCore and
/// PTP/IP are both thin implementations of this trait; everything above it
/// (datasets, vendor handlers, capture loop) is transport-agnostic.
#[async_trait]
pub trait PtpTransport: Send + Sync {
    fn kind(&self) -> TransportKind;
    fn is_open(&self) -> bool;

    /// Establish the link (USB session open / PTP/IP handshake). Idempotent.
    async fn open(&self) -> PtpResult<()>;
    async fn close(&self);

    /// Run one transaction. Implementations assign the transaction ID and
    /// serialise: PTP allows one outstanding operation per session.
    async fn execute(&self, request: PtpRequest) -> PtpResult<PtpResponse>;

    /// Asynchronous events pushed by the camera (interrupt pipe / event channel).
    /// Vendors that only expose polled events (Canon GetEvent, Nikon GetEvent)
    /// get them synthesised by their handler, not by the transport.
    fn events(&self) -> EventStream;
}

/// Transport-level diagnostics surfaced on the cable/power screen.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TransportHealth {
    pub round_trip_millis: Option<f64>,
    pub bytes_in: usize,
    pub bytes_out: usize,
    pub reconnects: usize,
    pub last_error: Option<String>,
}

/// Events buffered between the transport and its consumer. Keeps the newest
/// `capacity` events (older ones are dropped), and buffers from creation, so
/// an event pushed before anyone listens is not lost (like iOS's
/// `AsyncStream(bufferingPolicy: .bufferingNewest(256))`).
///
/// Cloning gives another handle on the same queue: consumers compete, as
/// several iterators of one `AsyncStream` would.
#[derive(Clone)]
pub struct EventStream {
    inner: Arc<EventQueueInner>,
}

struct EventQueueInner {
    state: Mutex<EventQueueState>,
    notify: Notify,
    capacity: usize,
}

struct EventQueueState {
    queue: VecDeque<PtpEvent>,
    finished: bool,
}

impl EventStream {
    /// The buffer size iOS used for camera events.
    pub const DEFAULT_CAPACITY: usize = 256;

    pub fn new(capacity: usize) -> Self {
        Self {
            inner: Arc::new(EventQueueInner {
                state: Mutex::new(EventQueueState {
                    queue: VecDeque::new(),
                    finished: false,
                }),
                notify: Notify::new(),
                capacity: capacity.max(1),
            }),
        }
    }

    /// Producer side: queue an event, dropping the oldest when full.
    pub fn push(&self, event: PtpEvent) {
        {
            let mut s = lock(&self.inner.state);
            if s.finished {
                return;
            }
            if s.queue.len() >= self.inner.capacity {
                s.queue.pop_front();
            }
            s.queue.push_back(event);
        }
        self.inner.notify.notify_one();
    }

    /// Producer side: no more events; `next` returns None once drained.
    pub fn finish(&self) {
        lock(&self.inner.state).finished = true;
        self.inner.notify.notify_waiters();
        self.inner.notify.notify_one();
    }

    /// Next event, waiting for one. None after `finish` once drained.
    pub async fn next(&self) -> Option<PtpEvent> {
        loop {
            let notified = self.inner.notify.notified();
            {
                let mut s = lock(&self.inner.state);
                if let Some(e) = s.queue.pop_front() {
                    return Some(e);
                }
                if s.finished {
                    return None;
                }
            }
            notified.await;
        }
    }

    /// Next event if one is already buffered.
    pub fn try_next(&self) -> Option<PtpEvent> {
        lock(&self.inner.state).queue.pop_front()
    }

    pub fn len(&self) -> usize {
        lock(&self.inner.state).queue.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl Default for EventStream {
    fn default() -> Self {
        Self::new(Self::DEFAULT_CAPACITY)
    }
}

impl std::fmt::Debug for EventStream {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EventStream")
            .field("buffered", &self.len())
            .finish()
    }
}

/// Locks a std mutex, recovering from poisoning (state stays usable).
pub(crate) fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ptp::codes::EventCode;

    #[tokio::test]
    async fn buffers_before_listening_and_drops_oldest() {
        let s = EventStream::new(2);
        s.push(PtpEvent::new(EventCode::OBJECT_ADDED, [1]));
        s.push(PtpEvent::new(EventCode::OBJECT_ADDED, [2]));
        s.push(PtpEvent::new(EventCode::OBJECT_ADDED, [3]));
        assert_eq!(s.next().await.unwrap().parameters, vec![2]);
        assert_eq!(s.clone().next().await.unwrap().parameters, vec![3]);
        let waiter = {
            let s = s.clone();
            tokio::spawn(async move { s.next().await })
        };
        tokio::task::yield_now().await;
        s.push(PtpEvent::new(EventCode::CAPTURE_COMPLETE, []));
        assert_eq!(
            waiter.await.unwrap().unwrap().code,
            EventCode::CAPTURE_COMPLETE
        );
        s.finish();
        assert!(s.next().await.is_none());
    }
}
