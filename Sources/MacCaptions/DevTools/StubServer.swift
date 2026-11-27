#if DEVTOOLS
import AppKit
import SwiftUI

// Tests and tools for the LLM features. Compiled only with  swift build -Xswiftc -DDEVTOOLS

// MARK: - A pretend LLM server (no network, no sockets)

/// Intercepts the client's requests and answers them from `handler`.
final class StubServer: URLProtocol {
    struct Answer { var status = 200; var body = ""; var headers: [String: String] = [:]; var delay: Double = 0; var redirect: String? = nil }
    private static let lock = NSLock()
    private static var _handler: ((URLRequest, [String: Any]) -> Answer)?
    private static var _log: [(request: URLRequest, body: [String: Any])] = []

    static var handler: ((URLRequest, [String: Any]) -> Answer)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); defer { lock.unlock() }; _handler = newValue; _log = [] }
    }
    static var log: [(request: URLRequest, body: [String: Any])] { lock.lock(); defer { lock.unlock() }; return _log }

    static var configuration: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubServer.self]
        return c
    }

    static func chat(_ content: String, finish: String = "stop") -> String {
        let obj: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content], "finish_reason": finish]],
                                  "usage": ["total_tokens": 50]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { stopped = true }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while case let n = stream.read(&buf, maxLength: buf.count), n > 0 { data.append(contentsOf: buf[0..<n]) }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.lock.lock(); Self._log.append((request, body)); let h = Self._handler; Self.lock.unlock()
        let a = h?(request, body) ?? Answer(status: 500)
        let url = request.url!
        DispatchQueue.global().asyncAfter(deadline: .now() + a.delay) { [self] in
            if stopped { return }
            if let target = a.redirect {
                let r = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: ["Location": target])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: r)
                client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let r = HTTPURLResponse(url: url, statusCode: a.status, httpVersion: nil, headerFields: a.headers)!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(a.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

// MARK: - End-to-end and benchmark helpers

/// MACCAPTIONS_LLM_STUB=<seconds>[,<n>]: the whole app talks to the pretend server, which answers after that delay
/// (every n-th request fails). MACCAPTIONS_LLM_STUB_WARMUP=<seconds> gives the warm-up request its own delay.
/// MACCAPTIONS_LLM_STUB_LOG=<file> records what was sent.
func stubbedClientConfigurationIfRequested() -> URLSessionConfiguration? {
    guard let spec = ProcessInfo.processInfo.environment["MACCAPTIONS_LLM_STUB"] else { return nil }
    let parts = spec.split(separator: ",").compactMap { Double($0) }
    let delay = parts.first ?? 0.5, failEvery = parts.count > 1 ? Int(parts[1]) : 0
    let counter = Counter()
    StubServer.handler = { _, body in
        let n = counter.next()
        let sent = (body["messages"] as? [[String: String]])?.last?["content"] ?? ""
        if let path = ProcessInfo.processInfo.environment["MACCAPTIONS_LLM_STUB_LOG"] {
            let entry = "=== request \(n) model=\(body["model"] as? String ?? "?") at \(String(format: "%.1f", Date().timeIntervalSince(PerfHarness.launched))) s\n\(sent)\n"
            if let h = FileHandle(forWritingAtPath: path) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(entry.utf8)); try? h.close() }
            else { try? entry.write(toFile: path, atomically: true, encoding: .utf8) }
        }
        if sent.hasSuffix("Good morning, everyone."),
           let w = ProcessInfo.processInfo.environment["MACCAPTIONS_LLM_STUB_WARMUP"].flatMap(Double.init) {
            return .init(body: StubServer.chat("大家早上好。"), delay: w)
        }
        if failEvery > 0 && n % failEvery == 0 { return .init(status: 500, body: "{\"error\":\"pretend failure\"}", delay: delay) }
        return .init(body: StubServer.chat("模拟大模型译文第\(n)号"), delay: delay)
    }
    return StubServer.configuration
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}
#endif
