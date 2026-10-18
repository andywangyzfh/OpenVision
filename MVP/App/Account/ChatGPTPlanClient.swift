import Foundation
import SubscriptionCore

actor ChatGPTPlanClient {
    init(account: ChatGPTAccountService) { /* Account owns UI; Keychain-backed actor owns credentials. */ }

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
        let accessToken = try await ChatGPTSessionStore.shared.accessToken()
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlanError.service("network_error") }
        if http.statusCode == 401 {
            await ChatGPTSessionStore.shared.discardIfMatching(accessToken)
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
        let accessToken = try await ChatGPTSessionStore.shared.accessToken()
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlanError.service("network_error") }
        if http.statusCode == 401 {
            await ChatGPTSessionStore.shared.discardIfMatching(accessToken)
            throw PlanError.reauthenticationRequired
        }
        guard http.statusCode == 200 else { throw PlanError.service("http_\(http.statusCode)") }
        return data
    }
}
