// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import NimbusLevitonBar

/// A fake my.leviton.com, slid under `LevitonClient` through a `URLProtocol`. Nothing a test
/// does through this ever reaches the network.
///
/// Usage:
///     let (client, http) = MockHTTP.makeClient()
///     http.stub("GET", "Residences/1/iotSwitches", .json(200, [Fixtures.iotSwitch(id: 5, name: "Desk")]))
///
/// Replies per route are a FIFO where the **last one repeats** — one stub serves a poll that
/// fires twice; a queue of two serves "fail once, then succeed". An unstubbed route answers
/// 599 with the route named in the body, so a test fails loudly instead of hanging.
///
/// Tests in this suite run serially (default XCTest), so one `current` instance at a time is
/// safe; `makeClient` installs a fresh one and forgets the previous.
final class MockHTTP: @unchecked Sendable {

    enum Reply {
        case json(Int, Any)                 // status + JSONSerialization-encodable body
        case data(Int, Data)                // status + raw bytes (bad JSON, empty, HTML…)
        case error(URLError.Code)           // transport failure, no response at all
        case delayed(TimeInterval, Int, Any)   // .json after a pause — keeps a write in flight
    }

    struct Recorded {
        let method: String
        /// Path relative to `/api/`, e.g. `IotSwitches/42`.
        let path: String
        let query: [String: String]
        let headers: [String: String]
        /// The JSON body, when there was one and it parsed.
        let body: [String: Any]?
        let bodyData: Data?
    }

    private let lock = NSLock()
    private var routes: [String: [Reply]] = [:]
    private var recorded: [Recorded] = []

    /// Everything the client sent, in order.
    var requests: [Recorded] { lock.lock(); defer { lock.unlock() }; return recorded }
    /// The requests for one route, in order.
    func requests(_ method: String, _ path: String) -> [Recorded] {
        requests.filter { $0.method == method && $0.path == path }
    }

    func stub(_ method: String, _ path: String, _ reply: Reply) {
        lock.lock(); defer { lock.unlock() }
        routes[Self.key(method, path), default: []].append(reply)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        routes = [:]
        recorded = []
    }

    /// A fresh client wired to a fresh mock. Keep the mock to stub routes and read requests.
    static func makeClient() -> (LevitonClient, MockHTTP) {
        let mock = MockHTTP()
        MockURLProtocol.current = mock
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockURLProtocol.self]
        return (LevitonClient(configuration: c), mock)
    }

    // MARK: The protocol's side

    fileprivate static func key(_ method: String, _ path: String) -> String { "\(method) \(path)" }

    fileprivate func serve(_ request: URLRequest) -> Reply {
        let url = request.url!
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        var path = url.path
        if path.hasPrefix("/api/") { path = String(path.dropFirst(5)) }
        let method = request.httpMethod ?? "GET"
        let data = Self.bodyData(request)
        let body = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }

        lock.lock(); defer { lock.unlock() }
        recorded.append(Recorded(method: method, path: path, query: query,
                                 headers: request.allHTTPHeaderFields ?? [:], body: body, bodyData: data))
        let key = Self.key(method, path)
        guard var queue = routes[key], let first = queue.first else {
            return .json(599, ["error": ["message": "MockHTTP: no stub for \(key)"]])
        }
        if queue.count > 1 {                      // FIFO; the last reply is sticky
            queue.removeFirst()
            routes[key] = queue
        }
        return first
    }

    /// URLSession hands the body to a protocol as a stream, never as `httpBody`.
    static func bodyData(_ request: URLRequest) -> Data? {
        if let d = request.httpBody { return d }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: size)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var current: MockHTTP?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let mock = Self.current else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch mock.serve(request) {
        case .error(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .json(let status, let obj):
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
            respond(status, data)
        case .data(let status, let data):
            respond(status, data)
        case .delayed(let pause, let status, let obj):
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
            DispatchQueue.global().asyncAfter(deadline: .now() + pause) { [self] in
                if !stopped { respond(status, data) }
            }
        }
    }

    private var stopped = false
    override func stopLoading() { stopped = true }

    private func respond(_ status: Int, _ data: Data) {
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
