//! Local IPv4 interface enumeration (broadcast targets, the FTP server's
//! advertised addresses, the "this Mac's address" UI), address hygiene for
//! discovery results, and the small socket helpers shared by discovery and
//! FTP. Ported from `NetworkInterfaces.swift` and `POSIXSockets.swift`.

use std::io;
use std::net::{Ipv4Addr, SocketAddrV4};
use std::time::Duration;

use socket2::{Domain, Protocol, Socket, Type};
use tokio::net::{TcpListener, TcpStream, UdpSocket};

/// One up IPv4 interface.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct NetworkInterface {
    pub name: String,
    pub address: String,
    pub netmask: String,
    pub broadcast: String,
    pub is_loopback: bool,
}

/// All IPv4 interfaces, loopback included (callers filter).
pub fn ipv4_interfaces() -> Vec<NetworkInterface> {
    let Ok(all) = if_addrs::get_if_addrs() else {
        return Vec::new();
    };
    all.into_iter()
        .filter_map(|i| match &i.addr {
            if_addrs::IfAddr::V4(v4) => {
                let address = v4.ip.to_string();
                let netmask = if v4.netmask.is_unspecified() {
                    "255.255.255.255".to_string()
                } else {
                    v4.netmask.to_string()
                };
                let broadcast =
                    broadcast_address(&address, &netmask).unwrap_or_else(|| address.clone());
                Some(NetworkInterface {
                    name: i.name.clone(),
                    is_loopback: v4.ip.is_loopback(),
                    address,
                    netmask,
                    broadcast,
                })
            }
            if_addrs::IfAddr::V6(_) => None,
        })
        .collect()
}

/// Non-loopback, non-APIPA IPv4 addresses, most useful first.
pub fn local_ipv4_addresses() -> Vec<String> {
    ipv4_interfaces()
        .into_iter()
        .filter(|i| !i.is_loopback && ip_filter::is_usable(&i.address))
        .map(|i| i.address)
        .collect()
}

/// Directed broadcast address of every usable interface plus the limited
/// broadcast 255.255.255.255 (deduplicated, in interface order).
pub fn broadcast_addresses() -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for i in ipv4_interfaces() {
        if !i.is_loopback && ip_filter::is_usable(&i.address) && !out.contains(&i.broadcast) {
            out.push(i.broadcast);
        }
    }
    let limited = "255.255.255.255".to_string();
    if !out.contains(&limited) {
        out.push(limited);
    }
    out
}

/// `address | !netmask` for dotted quads.
pub fn broadcast_address(address: &str, netmask: &str) -> Option<String> {
    let a = ip_filter::ipv4_octets(address)?;
    let m = ip_filter::ipv4_octets(netmask)?;
    Some(
        a.iter()
            .zip(m.iter())
            .map(|(a, m)| (a | !m).to_string())
            .collect::<Vec<_>>()
            .join("."),
    )
}

/// Address hygiene for discovery results (`IPAddressFilter` in Swift):
/// cameras advertising link-local addresses can't be reached and IPv6
/// link-local needs a scope we don't have.
pub mod ip_filter {
    pub fn ipv4_octets(s: &str) -> Option<[u8; 4]> {
        let parts: Vec<&str> = s.split('.').collect();
        if parts.len() != 4 {
            return None;
        }
        let mut out = [0u8; 4];
        for (o, p) in out.iter_mut().zip(parts) {
            *o = p.parse().ok()?;
        }
        Some(out)
    }

    pub fn is_ipv4(s: &str) -> bool {
        ipv4_octets(s).is_some()
    }

    pub fn is_ipv6(s: &str) -> bool {
        s.contains(':') && !is_ipv4(s)
    }

    /// APIPA (169.254/16) and IPv6 link-local (fe80::/10) are not usable;
    /// unspecified/loopback/limited broadcast aren't either. Everything else is.
    pub fn is_usable(address: &str) -> bool {
        let a = address.trim_matches(|c| c == ' ' || c == '\t');
        if let Some(o) = ipv4_octets(a) {
            if o[0] == 169 && o[1] == 254 {
                return false;
            }
            if o[0] == 0 || o[0] == 127 {
                return false;
            }
            return o != [255, 255, 255, 255];
        }
        if is_ipv6(a) {
            let bare = a.split('%').next().unwrap_or(a).to_lowercase();
            if bare == "::" || bare == "::1" {
                return false;
            }
            return !["fe8", "fe9", "fea", "feb"]
                .iter()
                .any(|p| bare.starts_with(p));
        }
        false
    }

    /// Picks the address to dial: usable IPv4 first, then usable IPv6.
    pub fn preferred<S: AsRef<str>>(addresses: &[S]) -> Option<String> {
        let usable: Vec<&str> = addresses
            .iter()
            .map(|s| s.as_ref())
            .filter(|s| is_usable(s))
            .collect();
        usable
            .iter()
            .find(|s| is_ipv4(s))
            .or_else(|| usable.first())
            .map(|s| s.to_string())
    }
}

/// Binds a listening IPv4 TCP socket (`port` 0 = ephemeral) with
/// `SO_REUSEADDR`, like Swift's `TCPListener`.
pub(crate) fn bind_tcp_listener(
    address: Ipv4Addr,
    port: u16,
    backlog: i32,
) -> io::Result<TcpListener> {
    let s = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP))?;
    s.set_reuse_address(true)?;
    s.set_nonblocking(true)?;
    s.bind(&SocketAddrV4::new(address, port).into())?;
    s.listen(backlog)?;
    TcpListener::from_std(s.into())
}

/// IPv4 UDP socket bound to `0.0.0.0:port` with address (and, on Apple,
/// port) reuse, optionally allowed to broadcast.
pub(crate) fn bind_udp(port: u16, broadcast: bool) -> io::Result<UdpSocket> {
    let s = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
    s.set_reuse_address(true)?;
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    s.set_reuse_port(true)?;
    if broadcast {
        s.set_broadcast(true)?;
    }
    s.set_nonblocking(true)?;
    s.bind(&SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, port).into())?;
    UdpSocket::from_std(s.into())
}

/// TCP connect with a deadline (`SocketConnector.blockingConnect`).
pub(crate) async fn connect_tcp(host: &str, port: u16, timeout: Duration) -> io::Result<TcpStream> {
    let stream = tokio::time::timeout(timeout, TcpStream::connect((host, port)))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "connect timed out"))??;
    let _ = stream.set_nodelay(true);
    Ok(stream)
}

/// UTF-8 when valid, else ISO-8859-1 (every byte maps to one char).
pub(crate) fn decode_text(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(s) => s.to_string(),
        Err(_) => bytes.iter().map(|&b| b as char).collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ip_address_filter() {
        use ip_filter::*;
        assert!(is_usable("192.168.1.20"));
        assert!(is_usable("10.0.0.5"));
        assert!(!is_usable("169.254.10.1"));
        assert!(!is_usable("127.0.0.1"));
        assert!(!is_usable("0.0.0.0"));
        assert!(!is_usable("fe80::1c99:4cff:fe1b:4f3a"));
        assert!(!is_usable("fe80::1%en0"));
        assert!(is_usable("fd00::2"));
        assert!(is_usable("2001:db8::1"));
        assert!(!is_usable("::1"));
        assert!(!is_usable("not an address"));
        assert_eq!(
            preferred(&["fe80::1", "fd00::2", "169.254.1.1", "192.168.0.9"]).as_deref(),
            Some("192.168.0.9")
        );
        assert_eq!(
            preferred(&["fe80::1", "fd00::2"]).as_deref(),
            Some("fd00::2")
        );
        assert_eq!(preferred(&["fe80::1", "169.254.9.9"]), None);
    }

    #[test]
    fn interfaces_and_broadcast() {
        assert_eq!(
            broadcast_address("192.168.1.20", "255.255.255.0").as_deref(),
            Some("192.168.1.255")
        );
        assert_eq!(
            broadcast_address("10.1.2.3", "255.255.0.0").as_deref(),
            Some("10.1.255.255")
        );
        assert_eq!(broadcast_address("bad", "255.0.0.0"), None);
        let locals = local_ipv4_addresses();
        assert!(!locals.contains(&"127.0.0.1".to_string()));
        assert!(locals.iter().all(|a| ip_filter::is_usable(a)));
        let bcasts = broadcast_addresses();
        assert!(bcasts.contains(&"255.255.255.255".to_string()));
        let mut dedup = bcasts.clone();
        dedup.sort();
        dedup.dedup();
        assert_eq!(dedup.len(), bcasts.len());
        // Loopback is enumerated but flagged.
        assert!(ipv4_interfaces()
            .iter()
            .any(|i| i.is_loopback && i.address == "127.0.0.1"));
    }

    #[test]
    fn decodes_latin1_fallback() {
        assert_eq!(decode_text(b"abc"), "abc");
        assert_eq!(decode_text(&[0x41, 0xE9]), "A\u{e9}");
    }
}
