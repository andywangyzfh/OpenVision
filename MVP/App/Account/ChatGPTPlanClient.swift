import Foundation
import Dispatch
import SubscriptionCore

actor ChatGPTPlanClient {
    typealias TokenSupplier = @Sendable () async throws -> String
    typealias TokenInvalidator = @Sendable (String) async -> Void
    private let session: URLSession
    private let tokenSupplier: TokenSupplier
    private let invalidateToken: TokenInvalidator
    private let nowNanoseconds: @Sendable () -> UInt64

    init(account: ChatGPTAccountService) {
        session = PlanHTTPTransport.session
        tokenSupplier = { try await ChatGPTSessionStore.shared.accessToken() }
        invalidateToken = { await ChatGPTSessionStore.shared.discardIfMatching($0) }
        nowNanoseconds = { DispatchTime.now().uptimeNanoseconds }
    }

    /// Inject an isolated transport and app-owned token operations for offline integration tests.
    /// The production initializer uses a cacheless ephemeral session and Keychain-backed tokens.
    init(session: URLSession, tokenSupplier: @escaping TokenSupplier, invalidateToken: @escaping TokenInvalidator,
         nowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.session = session
        self.tokenSupplier = tokenSupplier
        self.invalidateToken = invalidateToken
        self.nowNanoseconds = nowNanoseconds
    }

    func models() async throws -> [PlanModel] {
        let request = URLRequest(url: URL(string: SubscriptionContract.resource + "/models")!)
        let data = try await data(request)
        return try SubscriptionContract.models(from: data)
    }

    func respond(model: String, instructions: String, turns: [PlanTurn], observer: PlanRequestObserver? = nil) async throws -> String {
        var request = URLRequest(url: URL(string: SubscriptionContract.resource + "/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try SubscriptionContract.responseBody(model: model, instructions: instructions, turns: turns)
        request.timeoutInterval = 90
        // Never retry an inference automatically: a stream may already have consumed plan usage.
        let accessToken = try await tokenSupplier()
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let measurement = observer.map { RequestMeasurement(observer: $0, now: nowNanoseconds) }
        measurement?.record(.dispatched)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw PlanError.service("network_error") }
            measurement?.record(.headers, httpStatus: http.statusCode)
            if http.statusCode == 401 {
                await invalidateToken(accessToken)
                throw PlanError.reauthenticationRequired
            }
            guard http.statusCode == 200 else { throw PlanError.service("http_\(http.statusCode)") }
            // The plan-serving route can omit Content-Type. In that case the body still has
            // to pass SSE framing, event validation and response.completed below.
            if let contentType = http.value(forHTTPHeaderField: "Content-Type") {
                let mediaType = contentType.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard mediaType.caseInsensitiveCompare("text/event-stream") == .orderedSame else {
                    throw PlanError.malformedResponse
                }
            }
            let streamObserver: (@Sendable (PlanStreamObservation) -> Void)?
            if let measurement {
                streamObserver = { event in
                    switch event {
                    case .textDelta(let hasText): if hasText { measurement.recordFirstText() }
                    case .completed(let usage): measurement.record(.completed, usage: usage)
                    }
                }
            } else { streamObserver = nil }
            var stream = ResponseStream(observer: streamObserver)
            var receivedByte = false
            for try await byte in bytes {
                try Task.checkCancellation()
                if !receivedByte { receivedByte = true; measurement?.record(.firstByte) }
                try stream.consume(byte: byte)
            }
            measurement?.record(.eof)
            try Task.checkCancellation()
            let answer = try stream.finish()
            try Task.checkCancellation()
            measurement?.record(.returned)
            return answer
        } catch {
            // The caller receives the original typed error. Metrics never copy arbitrary
            // error descriptions, which can contain response content or credentials.
            measurement?.record(.failed)
            throw error
        }
    }

    private func data(_ initial: URLRequest) async throws -> Data {
        var request = initial
        request.timeoutInterval = 30
        let accessToken = try await tokenSupplier()
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlanError.service("network_error") }
        if http.statusCode == 401 {
            await invalidateToken(accessToken)
            throw PlanError.reauthenticationRequired
        }
        guard http.statusCode == 200 else { throw PlanError.service("http_\(http.statusCode)") }
        return data
    }
}

/// Mutable first-delta tracking is lock protected because the stream callback is Sendable.
/// Observer calls occur outside the lock and contain only fixed fields and aggregate usage.
private final class RequestMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    private var sawText = false
    private let observer: PlanRequestObserver
    private let now: @Sendable () -> UInt64
    private let started: UInt64
    init(observer: @escaping PlanRequestObserver, now: @escaping @Sendable () -> UInt64) {
        self.observer = observer; self.now = now; started = now()
    }
    func recordFirstText() {
        lock.lock()
        guard !sawText else { lock.unlock(); return }
        sawText = true; lock.unlock()
        record(.firstTextDelta)
    }
    func record(_ milestone: PlanRequestMilestone, httpStatus: Int? = nil, usage: PlanTokenUsage? = nil) {
        let instant = milestone == .dispatched ? started : now()
        observer(.init(milestone: milestone, elapsedNanoseconds: instant >= started ? instant - started : 0,
                       httpStatus: httpStatus, usage: usage))
    }
}
