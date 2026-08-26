// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// SSDP discovery, targeted at LG televisions.
///
/// One 105-byte datagram to the multicast group `239.255.255.250:1900` carrying
/// `ST: urn:lge:device:tv:1`; every device whose type matches answers with a single unicast
/// datagram straight back to our source port and everything else stays silent. Nothing sweeps
/// the address space — see docs/lg-tv-plan.md, "How the discovery actually works".
///
/// `MX` is the response-spreading window: responders randomise their reply somewhere inside it
/// so a hundred UPnP devices do not answer in one burst. Since the `ST` filter leaves exactly
/// one responder here, the spread buys nothing and only adds latency, which is why `MX: 1` and
/// returning on the first match is the whole strategy.
enum Discovery {

    static let group = "239.255.255.250"
    static let port: UInt16 = 1900
    static let searchTarget = "urn:lge:device:tv:1"

    struct Response {
        /// The address the TV answered *from* — the one to connect to.
        var address: String
        var headers: [String: String]
        /// Seconds between the M-SEARCH going out and this reply arriving.
        var elapsed: TimeInterval

        var usn: String? { headers["USN"] }
        var location: String? { headers["LOCATION"] }
        var server: String? { headers["SERVER"] }
        /// The stable identity: `uuid:…`, with the `::urn:…` service suffix stripped.
        /// Persist this, never the address. Note the DIAL service on the same TV advertises a
        /// *different* uuid, which is why the search is filtered to `urn:lge:device:tv:1`.
        var udn: String? { usn?.components(separatedBy: "::").first }
    }

    /// The device description XML at a responder's `LOCATION`. Where the MACs live, which is
    /// what Wake-on-LAN would need later.
    struct Description {
        var friendlyName: String?
        var modelName: String?
        var udn: String?
        var wiredMac: String?
        var wifiMac: String?
    }

    enum Failure: LocalizedError {
        case socket(String, Int32)
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .socket(let call, let err): return "\(call) failed: \(String(cString: strerror(err))) (\(err))"
            case .notFound(let what): return what
            }
        }
    }

    /// Send one M-SEARCH and collect replies until `timeout`, or until the first one when
    /// `stopOnFirst`.
    static func search(mx: Int = 1, timeout: TimeInterval = 3, stopOnFirst: Bool = true,
                       onResponse: ((Response) -> Void)? = nil) throws -> [Response] {
        let message = """
            M-SEARCH * HTTP/1.1\r
            HOST: \(group):\(port)\r
            MAN: "ssdp:discover"\r
            MX: \(mx)\r
            ST: \(searchTarget)\r
            \r

            """

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw Failure.socket("socket", errno) }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // A blocking recvfrom with a deadline is all the loop below needs; 250 ms slices keep
        // the overall timeout honest without spinning.
        var slice = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &slice, socklen_t(MemoryLayout<timeval>.size))

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        dest.sin_addr.s_addr = inet_addr(group)

        // This Mac has *two* interfaces on the same 10.0.0.0/8 (en0 10.1.0.1, en1 10.10.1.83),
        // and an unqualified multicast send goes out exactly one of them — whichever the route
        // table picked, which is not necessarily the one the television is on. So the datagram
        // goes out every eligible interface in turn, on the one socket, and every reply comes
        // back to it. An empty list means "let the routing table decide", which is right on a
        // machine with one interface.
        let interfaces = multicastInterfaces()
        let payload = Data(message.utf8)

        func blast() throws {
            for source in (interfaces.isEmpty ? [nil] : interfaces.map { Optional($0) }) {
                if let source {
                    var address = in_addr(s_addr: inet_addr(source))
                    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &address, socklen_t(MemoryLayout<in_addr>.size))
                }
                let sent = payload.withUnsafeBytes { body -> Int in
                    withUnsafePointer(to: &dest) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            sendto(fd, body.baseAddress, body.count, 0, sa,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                guard sent > 0 else { throw Failure.socket("sendto", errno) }
            }
        }

        let started = Date()
        try blast()
        // macOS local-network privacy silently drops the *first* multicast send from a binary
        // it has not seen before — a freshly built one every time, during development. One
        // resend a second in covers that, and any ordinary lost datagram with it.
        var resent = false

        var found: [Response] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date().timeIntervalSince(started) < timeout {
            if !resent, Date().timeIntervalSince(started) > 1 { resent = true; try blast() }
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buffer, buffer.count, 0, sa, &fromLen)
                }
            }
            if n <= 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw Failure.socket("recvfrom", errno)
            }
            let text = String(decoding: buffer[0..<n], as: UTF8.self)
            let reply = Response(address: address(of: from), headers: parse(text),
                                 elapsed: Date().timeIntervalSince(started))
            // A TV answers more than once to the same search; one entry per address.
            guard !found.contains(where: { $0.address == reply.address }) else { continue }
            found.append(reply)
            onResponse?(reply)
            if stopOnFirst { break }
        }
        return found
    }

    /// Fetch and parse the UPnP device description a responder points at.
    static func describe(location: String, timeout: TimeInterval = 5) throws -> Description {
        guard let url = URL(string: location) else { throw Failure.notFound("bad LOCATION: \(location)") }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        var result: Result<Data, Error>?
        let done = DispatchSemaphore(value: 0)
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, _, error in
            result = error.map { .failure($0) } ?? .success(data ?? Data())
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        guard let result else { throw Failure.notFound("no answer from \(location)") }
        let xml = String(decoding: try result.get(), as: UTF8.self)
        return Description(friendlyName: tag("friendlyName", xml), modelName: tag("modelName", xml),
                           udn: tag("UDN", xml), wiredMac: tag("wiredMac", xml), wifiMac: tag("wifiMac", xml))
    }

    // MARK: - Parsing

    /// SSDP is HTTP syntax over UDP: a status line then `Name: value` headers. Names are
    /// upper-cased so lookups do not depend on a vendor's capitalisation.
    private static func parse(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for raw in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let name = raw[raw.startIndex..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers[name] = value }
        }
        return headers
    }

    /// Every up, multicast-capable, non-loopback IPv4 interface, by address.
    private static func multicastInterfaces() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        var addresses: [String] = []
        for interface in sequence(first: head, next: { $0.pointee.ifa_next }) {
            guard let raw = interface.pointee.ifa_addr, raw.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_MULTICAST != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let text = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address(of: $0.pointee) }
            if !text.isEmpty, !addresses.contains(text) { addresses.append(text) }
        }
        return addresses
    }

    private static func address(of addr: sockaddr_in) -> String {
        var addr = addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
        return String(cString: text)
    }

    /// Enough XML for a flat description document; a parser delegate would be five times the
    /// code for the same five fields.
    private static func tag(_ name: String, _ xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"), let close = xml.range(of: "</\(name)>"),
              open.upperBound <= close.lowerBound else { return nil }
        let value = xml[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
