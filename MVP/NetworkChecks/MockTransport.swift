import Foundation

// Symbol needed by the real client's production initializer. Offline checks never construct
// this initializer and never touch ChatGPTSessionStore.shared or the real Keychain.
@MainActor
final class ChatGPTAccountService {}

final class FixtureVault: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String? = "synthetic-old-token"
    private var discarded: [String] = []
    func token() -> String? { lock.lock(); defer { lock.unlock() }; return current }
    func replace(_ token: String?) { lock.lock(); current = token; lock.unlock() }
    func discardIfMatching(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        discarded.append(token)
        if current == token { current = nil }
    }
    func invalidationCalls() -> [String] { lock.lock(); defer { lock.unlock() }; return discarded }
}

struct MockReply: Sendable {
    var status = 200
    var mime: String? = "text/event-stream; charset=utf-8"
    var body = Data()
    var failure: URLError.Code?
    var chunkSize = 2
    var trailingFailure: URLError.Code?
    var beforeResponse: (@Sendable () -> Void)?
}

final class MockLedger: @unchecked Sendable {
    static let shared = MockLedger()
    private let lock = NSLock()
    private var replies: [MockReply] = []
    private var requests: [URLRequest] = []
    func reset(_ replies: [MockReply]) {
        lock.lock(); defer { lock.unlock() }
        self.replies = replies; requests = []
    }
    func record(_ request: URLRequest) -> MockReply? {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return replies.isEmpty ? nil : replies.removeFirst()
    }
    func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

/// Intercepts EVERY request in the injected ephemeral session, including unexpected hosts.
/// Missing fixtures fail locally; they can never fall through to the network.
final class OfflineURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let reply = MockLedger.shared.record(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        reply.beforeResponse?()
        if let code = reply.failure {
            client?.urlProtocol(self, didFailWithError: URLError(code)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: reply.mime.map { ["Content-Type": $0] } ?? [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let bytes = [UInt8](reply.body)
        let size = max(1, reply.chunkSize)
        for start in stride(from: 0, to: bytes.count, by: size) {
            client?.urlProtocol(self, didLoad: Data(bytes[start..<min(start + size, bytes.count)]))
        }
        if let code = reply.trailingFailure { client?.urlProtocol(self, didFailWithError: URLError(code)) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}
