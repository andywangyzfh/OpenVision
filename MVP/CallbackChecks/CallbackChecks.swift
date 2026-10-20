import Darwin
import Foundation
import Network
import SubscriptionCore

private struct CallbackCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private final class CallbackLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [[URLQueryItem]] = []
    func append(_ query: [URLQueryItem]) { lock.lock(); defer { lock.unlock() }; queries.append(query) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return queries.count }
}

@MainActor private var assertions = 0
@MainActor private func check(_ description: String, _ value: @autoclosure () -> Bool) throws {
    guard value() else { throw CallbackCheckFailure(description: description) }
    assertions += 1
}

private func within<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw CallbackCheckFailure(description: "Local callback operation timed out")
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}

private func wait(_ waiter: PlanCallbackWaiter) async throws -> [URLQueryItem] {
    try await within {
        try await withTaskCancellationHandler(operation: { try await waiter.result() }, onCancel: {
            waiter.complete(.failure(CancellationError()))
        })
    }
}

private func request(_ port: UInt16, path: String = "/auth/callback", query: [URLQueryItem]) async throws -> (Int, String) {
    var components = URLComponents()
    components.scheme = "http"; components.host = "127.0.0.1"; components.port = Int(port)
    components.path = path; components.queryItems = query
    guard let url = components.url else { throw CallbackCheckFailure(description: "Bad synthetic loopback URL") }
    var request = URLRequest(url: url); request.timeoutInterval = 3
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw CallbackCheckFailure(description: "No local HTTP response") }
    return (response.statusCode, String(decoding: data, as: UTF8.self))
}

@main
enum CallbackChecks {
    @MainActor static func main() async {
        do {
            try await httpMatching()
            try await rejectedAuthorizationParameters()
            try await waiterRaces()
            try await stopBeforeReady()
            print("PASS: \(assertions) production callback/listener assertions using real 127.0.0.1 HTTP. Synthetic codes only; no user account, external network, or glasses tested.")
        } catch {
            FileHandle.standardError.write(Data("FAIL: local callback integration: \(error). Listener startup failure may indicate a localhost sandbox restriction; do not broaden permissions automatically.\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func httpMatching() async throws {
        let listener = try PlanLoopbackListener()
        defer { listener.stop() }
        let port = try await within { try await listener.start() }
        let attempt = SignInAttempt(hostID: "urn:uuid:synthetic-callback-check", port: port)
        listener.expectedState = attempt.state
        let ledger = CallbackLedger(), waiter = PlanCallbackWaiter()
        listener.onQuery = { query in ledger.append(query); waiter.complete(.success(query)) }
        let good = [URLQueryItem(name: "state", value: attempt.state), .init(name: "code", value: "synthetic-code"), .init(name: "client_id", value: "oaiapp_synthetic")]
        let invalid: [(String, [URLQueryItem])] = [
            ("/favicon.ico", good),
            ("/auth/callback", [.init(name: "state", value: "wrong"), .init(name: "code", value: "synthetic-code")]),
            ("/auth/callback", [.init(name: "code", value: "synthetic-code")]),
            ("/auth/callback", good + [.init(name: "state", value: attempt.state)])
        ]
        for (path, query) in invalid {
            let response = try await request(port, path: path, query: query)
            try check("Wrong path/state/missing/duplicate state must be 404", response.0 == 404)
            try check("Invalid HTTP must not complete callback", ledger.count == 0)
        }
        let response = try await request(port, query: good)
        try check("Valid callback must return 200", response.0 == 200)
        try check("Callback response must not echo synthetic code", !response.1.contains("synthetic-code"))
        let query = try await wait(waiter)
        let callback = try attempt.callback(query)
        try check("Real listener query validates through production SignInAttempt", callback.code == "synthetic-code" && callback.clientID == "oaiapp_synthetic")
        _ = try await request(port, query: good)
        try check("Repeated HTTP must deliver callback once only", ledger.count == 1)
        let later = try await wait(waiter)
        try check("Completed waiter retains one stable result", later == query)
    }

    @MainActor private static func rejectedAuthorizationParameters() async throws {
        for duplicateCode in [false, true] {
            let listener = try PlanLoopbackListener()
            defer { listener.stop() }
            let port = try await within { try await listener.start() }
            let attempt = SignInAttempt(hostID: "urn:uuid:synthetic-rejection-check", port: port)
            listener.expectedState = attempt.state
            let waiter = PlanCallbackWaiter()
            listener.onQuery = { waiter.complete(.success($0)) }
            var query = [URLQueryItem(name: "state", value: attempt.state)]
            if duplicateCode {
                query += [.init(name: "code", value: "synthetic-one"), .init(name: "code", value: "synthetic-two"), .init(name: "client_id", value: "oaiapp_synthetic")]
            } else { query += [.init(name: "error", value: "access_denied")] }
            let response = try await request(port, query: query)
            try check("Matching provider response reaches callback validator", response.0 == 200)
            let received = try await wait(waiter)
            do {
                _ = try attempt.callback(received)
                throw CallbackCheckFailure(description: "Unsafe authorization parameters were accepted")
            } catch let error as PlanError {
                try check("Production validator rejects provider denial / duplicate code", error == (duplicateCode ? .invalidCallback : .denied))
            }
        }
    }

    @MainActor private static func waiterRaces() async throws {
        let early = PlanCallbackWaiter()
        let synthetic = [URLQueryItem(name: "code", value: "synthetic-early")]
        early.complete(.success(synthetic)); early.complete(.failure(PlanError.denied))
        let earlyResult = try await wait(early)
        try check("Completion before awaiting is retained", earlyResult == synthetic)

        // Exercise both completion orderings deliberately before concurrent cancellation races.
        let cancelled = PlanCallbackWaiter()
        cancelled.complete(.failure(CancellationError())); cancelled.complete(.success(synthetic))
        do { _ = try await wait(cancelled); throw CallbackCheckFailure(description: "Cancellation outcome was overwritten") }
        catch is CancellationError { assertions += 1 }

        for _ in 0..<20 {
            let waiter = PlanCallbackWaiter()
            let task = Task {
                try await withTaskCancellationHandler(operation: { try await waiter.result() }, onCancel: {
                    waiter.complete(.failure(CancellationError()))
                })
            }
            DispatchQueue.global().async { waiter.complete(.success(synthetic)) }
            task.cancel()
            do {
                let result = try await task.value
                try check("Racing success remains intact", result == synthetic)
                let repeated = try await wait(waiter)
                try check("One-shot success remains stable after race", repeated == result)
            } catch is CancellationError {
                assertions += 1
                do { _ = try await wait(waiter); throw CallbackCheckFailure(description: "Racing cancellation was overwritten") }
                catch is CancellationError { assertions += 1 }
            }
        }
    }

    @MainActor private static func stopBeforeReady() async throws {
        let stopped = try PlanLoopbackListener()
        stopped.stop()
        do { _ = try await within { try await stopped.start() }; throw CallbackCheckFailure(description: "Stopped listener started") }
        catch is CancellationError { assertions += 1 }

        // Hold the actual serial lifecycle queue so Stop is queued before any .ready callback.
        let queue = DispatchQueue(label: "openvision.callback-check.pending-ready")
        queue.suspend()
        let listener = try PlanLoopbackListener(queue: queue)
        let pending = Task { try await listener.start() }
        await Task.yield()
        listener.stop()
        queue.resume()
        do { _ = try await pending.value; throw CallbackCheckFailure(description: "Ready continuation escaped Stop") }
        catch is CancellationError { assertions += 1 }
    }
}
