import Foundation

enum NetworkInfo {
    /// Non-loopback IPv4 addresses, Wi-Fi/Ethernet first, so the printed URL is
    /// the one the iPad can actually reach.
    static func localIPv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var preferred: [String] = []
        var others: [String] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let name = String(cString: ptr.pointee.ifa_name)
            // en0/en1 are Wi-Fi and Ethernet; bridge/utun/awdl are not useful here.
            if name.hasPrefix("en") { preferred.append(ip) } else { others.append(ip) }
        }
        return preferred + others
    }

    static var localHostName: String? {
        let name = ProcessInfo.processInfo.hostName
        return name.isEmpty ? nil : name
    }
}
