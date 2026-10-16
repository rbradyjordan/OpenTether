import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Local IPv4 interface enumeration (getifaddrs) used for broadcast targets,
/// the FTP server's advertised addresses and the "phone's own address" UI.
public enum NetworkInterfaces {
    public struct Interface: Hashable, Sendable {
        public var name: String
        public var address: String
        public var netmask: String
        public var broadcast: String
        public var isLoopback: Bool
    }

    private static let IFF_UP_FLAG: UInt32 = 0x1
    private static let IFF_LOOPBACK_FLAG: UInt32 = 0x8

    /// All up IPv4 interfaces, loopback included (callers filter).
    public static func ipv4Interfaces() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [Interface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET else { continue }
            let flags = UInt32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP_FLAG != 0 else { continue }
            guard let addr = POSIXNet.describe(sa)?.host else { continue }
            var mask = "255.255.255.255"
            if let m = ifa.pointee.ifa_netmask, let s = POSIXNet.describe(m)?.host { mask = s }
            let bcast = broadcastAddress(address: addr, netmask: mask) ?? addr
            out.append(Interface(name: String(cString: ifa.pointee.ifa_name), address: addr, netmask: mask,
                                 broadcast: bcast, isLoopback: flags & IFF_LOOPBACK_FLAG != 0))
        }
        return out
    }

    /// Non-loopback, non-APIPA IPv4 addresses, most useful first.
    public static func localIPv4Addresses() -> [String] {
        ipv4Interfaces()
            .filter { !$0.isLoopback && IPAddressFilter.isUsable($0.address) }
            .map(\.address)
    }

    /// Directed broadcast address of every usable interface plus the limited
    /// broadcast 255.255.255.255 (deduplicated).
    public static func broadcastAddresses() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for i in ipv4Interfaces() where !i.isLoopback && IPAddressFilter.isUsable(i.address) {
            if seen.insert(i.broadcast).inserted { out.append(i.broadcast) }
        }
        if seen.insert("255.255.255.255").inserted { out.append("255.255.255.255") }
        return out
    }

    /// `address | ~netmask` for dotted quads.
    public static func broadcastAddress(address: String, netmask: String) -> String? {
        guard let a = IPAddressFilter.ipv4Octets(address), let m = IPAddressFilter.ipv4Octets(netmask) else { return nil }
        return zip(a, m).map { String($0 | ~$1) }.joined(separator: ".")
    }
}

/// Address hygiene for discovery results: cameras advertising link-local
/// addresses can't be reached and IPv6 link-local needs a scope we don't have.
public enum IPAddressFilter {
    public static func ipv4Octets(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard let v = UInt8(p) else { return nil }
            out.append(v)
        }
        return out
    }

    public static func isIPv4(_ s: String) -> Bool { ipv4Octets(s) != nil }
    public static func isIPv6(_ s: String) -> Bool { s.contains(":") && !isIPv4(s) }

    /// APIPA (169.254/16) and IPv6 link-local (fe80::/10) are not usable;
    /// unspecified/loopback aren't either. Everything else is.
    public static func isUsable(_ address: String) -> Bool {
        let a = address.trimmingCharacters(in: .whitespaces)
        if let o = ipv4Octets(a) {
            if o[0] == 169 && o[1] == 254 { return false }
            if o[0] == 0 || o[0] == 127 { return false }
            if o == [255, 255, 255, 255] { return false }
            return true
        }
        if isIPv6(a) {
            let bare = a.split(separator: "%").first.map(String.init)?.lowercased() ?? a.lowercased()
            if bare == "::" || bare == "::1" { return false }
            if bare.hasPrefix("fe8") || bare.hasPrefix("fe9") || bare.hasPrefix("fea") || bare.hasPrefix("feb") { return false }
            return true
        }
        return false
    }

    /// Picks the address to dial: usable IPv4 first, then usable IPv6.
    public static func preferred(_ addresses: [String]) -> String? {
        let usable = addresses.filter(isUsable)
        return usable.first(where: isIPv4) ?? usable.first
    }
}
