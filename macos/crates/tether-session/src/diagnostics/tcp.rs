//! TCP connect with a timeout, for the wireless diagnostic ("does the
//! camera answer on 15740 / 80?"). Ports the app's `TCPProbe`.

use std::time::Duration;

use tokio::net::TcpStream;

pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(2);

/// True when `host:port` accepts a TCP connection within `timeout`.
pub async fn reachable(host: &str, port: u16, timeout: Duration) -> bool {
    matches!(
        tokio::time::timeout(timeout, TcpStream::connect((host, port))).await,
        Ok(Ok(_))
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn open_and_closed_ports() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        assert!(reachable("127.0.0.1", port, DEFAULT_TIMEOUT).await);
        drop(listener);
        assert!(!reachable("127.0.0.1", port, Duration::from_millis(500)).await);
    }
}
