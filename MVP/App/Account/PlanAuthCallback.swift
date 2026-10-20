import Foundation
import Network
import SubscriptionCore

/// Early completion and competing cancellation/callbacks resolve exactly once.
final class PlanCallbackWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<[URLQueryItem], Error>] = []
    private var outcome: Result<[URLQueryItem], Error>?
    func result() async throws -> [URLQueryItem] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let outcome { lock.unlock(); continuation.resume(with: outcome) }
            else { continuations.append(continuation); lock.unlock() }
        }
    }
    func complete(_ result: Result<[URLQueryItem], Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let pending = continuations; continuations.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(with: result) }
    }
}

/// Listener lifecycle/connection state is confined to its serial queue; configuration and the
/// one-shot callback claim are protected by a lock because the account configures it on MainActor.
final class PlanLoopbackListener: @unchecked Sendable {
    private let configurationLock = NSLock()
    private var state = ""
    private var queryHandler: (@Sendable ([URLQueryItem]) -> Void)?
    private var failureHandler: (@Sendable () -> Void)?
    private var delivered = false
    var expectedState: String {
        get { configurationLock.lock(); defer { configurationLock.unlock() }; return state }
        set { configurationLock.lock(); defer { configurationLock.unlock() }; state = newValue }
    }
    var onQuery: (@Sendable ([URLQueryItem]) -> Void)? {
        get { configurationLock.lock(); defer { configurationLock.unlock() }; return queryHandler }
        set { configurationLock.lock(); defer { configurationLock.unlock() }; queryHandler = newValue }
    }
    var onFailure: (@Sendable () -> Void)? {
        get { configurationLock.lock(); defer { configurationLock.unlock() }; return failureHandler }
        set { configurationLock.lock(); defer { configurationLock.unlock() }; failureHandler = newValue }
    }
    private let listener: NWListener
    private let queue: DispatchQueue
    // Only access these on queue, including continuation installation and stop-before-start.
    private var ready: CheckedContinuation<UInt16, Error>?
    private var connections: [NWConnection] = []
    private var started = false
    private var stopped = false

    init(queue: DispatchQueue = DispatchQueue(label: "openvision.plan-loopback")) throws {
        self.queue = queue
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !stopped else { continuation.resume(throwing: CancellationError()); return }
                    guard !started else { continuation.resume(throwing: PlanError.service("listener_already_started")); return }
                    started = true; ready = continuation
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            if let port = self.listener.port { self.ready?.resume(returning: port.rawValue); self.ready = nil }
                        case .failed:
                            guard !self.stopped else { return }
                            self.ready?.resume(throwing: PlanError.service("callback_listener_failed")); self.ready = nil
                            self.onFailure?()
                            self.stopOnQueue()
                        case .cancelled: self.stopOnQueue()
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
                    listener.start(queue: queue)
                }
            }
        }, onCancel: { self.stop() })
    }

    func stop() { queue.async { [self] in stopOnQueue() } }

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        ready?.resume(throwing: CancellationError()); ready = nil
        listener.cancel()
        connections.forEach { $0.cancel() }; connections.removeAll()
    }

    private func handle(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        connections.append(connection)
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    private func match(_ target: URLComponents?) -> (valid: Bool, callback: (@Sendable ([URLQueryItem]) -> Void)?) {
        let query = target?.queryItems ?? []
        let states = query.filter { $0.name == "state" }
        configurationLock.lock(); defer { configurationLock.unlock() }
        let valid = target?.path == "/auth/callback" && !state.isEmpty && states.count == 1 && states.first?.value == state
        guard valid, !delivered else { return (valid, nil) }
        delivered = true
        return (true, queryHandler)
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, complete, error in
            guard let self, !self.stopped else { connection.cancel(); return }
            var data = accumulated
            if let chunk { data.append(chunk) }
            if data.range(of: Data("\r\n\r\n".utf8)) == nil && !complete && error == nil && data.count < 32_768 {
                self.receive(connection, accumulated: data); return
            }
            let line = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            let target = parts.count == 3 && parts[0] == "GET" ? URLComponents(string: String(parts[1])) : nil
            let result = self.match(target)
            let body = result.valid ? "Return to OpenVision to finish sign-in." : "Not found"
            let response = "HTTP/1.1 \(result.valid ? "200 OK" : "404 Not Found")\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
                connection.cancel()
                self?.connections.removeAll { $0 === connection }
            })
            result.callback?(target?.queryItems ?? [])
        }
    }
}
