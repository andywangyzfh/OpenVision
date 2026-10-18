import Foundation
import SubscriptionCore

actor ChatGPTPlanClient {
    typealias TokenSupplier = @Sendable () async throws -> String
    typealias TokenInvalidator = @Sendable (String) async -> Void
    private let session: URLSession
    private let tokenSupplier: TokenSupplier
    private let invalidateToken: TokenInvalidator

    init(account: ChatGPTAccountService) {
        session = PlanHTTPTransport.session
        tokenSupplier = { try await ChatGPTSessionStore.shared.accessToken() }
        invalidateToken = { await ChatGPTSessionStore.shared.discardIfMatching($0) }
    }

    /// Inject an isolated transport and app-owned token operations for offline integration tests.
    /// The production initializer uses a cacheless ephemeral session and Keychain-backed tokens.
    init(session: URLSession, tokenSupplier: @escaping TokenSupplier, invalidateToken: @escaping TokenInvalidator) {
        self.session = session
        self.tokenSupplier = tokenSupplier
        self.invalidateToken = invalidateToken
    }

    func models() async throws -> [PlanModel] {
        let request = URLRequest(url: URL(string: SubscriptionContract.resource + "/models")!)
        let data = try await data(request)
        return try SubscriptionContract.models(from: data)
    }

    func respond(model: String, instructions: String, turns: [PlanTurn]) async throws -> String {
        var request = URLRequest(url: URL(string: SubscriptionContract.resource + "/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try SubscriptionContract.responseBody(model: model, instructions: instructions, turns: turns)
        request.timeoutInterval = 90
        // Never retry an inference automatically: a stream may already have consumed plan usage.
        let accessToken = try await tokenSupplier()
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlanError.service("network_error") }
        if http.statusCode == 401 {
            await invalidateToken(accessToken)
            throw PlanError.reauthenticationRequired
        }
        guard http.statusCode == 200 else { throw PlanError.service("http_\(http.statusCode)") }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
            throw PlanError.malformedResponse
        }
        var stream = ResponseStream()
        for try await byte in bytes {
            try Task.checkCancellation()
            try stream.consume(byte: byte)
        }
        return try stream.finish()
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
