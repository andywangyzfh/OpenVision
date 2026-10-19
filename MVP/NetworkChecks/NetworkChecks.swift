import Darwin
import Foundation
import SubscriptionCore

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw CheckFailure(message) }
}

private func body(of request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        result.append(contentsOf: buffer.prefix(count))
    }
    return result
}

private let completed = #"{"type":"response.completed","response":{"status":"completed"}}"#
private func sse(_ events: [String]) -> Data {
    Data(events.map { "data: " + $0 + "\r\n\r\n" }.joined().utf8)
}

private func fixture(_ reply: MockReply) -> (ChatGPTPlanClient, URLSession, FixtureVault) {
    MockLedger.shared.reset([reply])
    let vault = FixtureVault()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OfflineURLProtocol.self]
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    let session = URLSession(configuration: configuration)
    let client = ChatGPTPlanClient(session: session, tokenSupplier: {
        guard let token = vault.token() else { throw PlanError.reauthenticationRequired }
        return token
    }, invalidateToken: { vault.discardIfMatching($0) })
    return (client, session, vault)
}

private enum Endpoint: String, CaseIterable {
    case models, responses
    func call(_ client: ChatGPTPlanClient) async throws {
        if self == .models { _ = try await client.models() }
        else { _ = try await client.respond(model: "fixture-plan", instructions: "用中文回答", turns: [.init(role: "user", text: "你好")]) }
    }
}

@main
struct NetworkChecks {
    static func main() async {
        var scenarios: [(String, @Sendable () async throws -> Void)] = []
        scenarios.append(("models uses the authorized public endpoint and preserves catalog ordering", {
            let json = #"{"models":[{"slug":"second","display_name":"Second","visibility":"list","input_modalities":["text","image"]},{"slug":"hidden","visibility":"hide"},{"slug":"first","visibility":"list"}]}"#
            let (client, session, vault) = fixture(.init(mime: "application/json", body: Data(json.utf8)))
            defer { session.invalidateAndCancel() }
            let models = try await client.models()
            try expect(models.map(\.id) == ["second", "first"], "Model catalog order or visibility wrong")
            let requests = MockLedger.shared.snapshot()
            try expect(requests.count == 1 && requests[0].url?.absoluteString == SubscriptionContract.resource + "/models", "Wrong catalog endpoint or retry")
            try expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-old-token", "Injected token was not used")
            try expect(vault.invalidationCalls().isEmpty, "Valid request invalidated account")
        }))
        scenarios.append(("text/image and assistant history survive real URLSession streaming", {
            let response = sse([#"{"type":"response.output_text.delta","delta":"你好 "}"#, #"{"type":"response.output_text.delta","delta":"Hello"}"#, completed])
            let (client, session, vault) = fixture(.init(body: response, chunkSize: 1))
            defer { session.invalidateAndCancel() }
            let image = Data("synthetic-jpeg".utf8)
            let answer = try await client.respond(model: "fixture-plan", instructions: "Use the selected language.", turns: [
                .init(role: "user", text: "Earlier question"), .init(role: "assistant", text: "Earlier answer"),
                .init(role: "user", text: "看看这个", imageJPEG: image)])
            try expect(answer == "你好 Hello", "Fragmented UTF-8 SSE reply was corrupted")
            let requests = MockLedger.shared.snapshot()
            try expect(requests.count == 1 && requests[0].url?.path == "/v1/responses" && requests[0].httpMethod == "POST", "Wrong inference endpoint, method or retry")
            try expect(requests[0].value(forHTTPHeaderField: "Accept") == "text/event-stream", "SSE Accept header missing")
            let payload = try JSONSerialization.jsonObject(with: body(of: requests[0])) as! [String: Any]
            try expect(payload["store"] as? Bool == false && payload["stream"] as? Bool == true, "Subscription stream/store requirements changed")
            let input = payload["input"] as! [[String: Any]]
            try expect(input.count == 3 && input[1]["role"] as? String == "assistant", "Assistant history missing")
            let content = input[2]["content"] as! [[String: Any]]
            try expect(content.last?["image_url"] as? String == "data:image/jpeg;base64," + image.base64EncodedString(), "JPEG payload changed")
            try expect(vault.invalidationCalls().isEmpty, "Successful inference invalidated account")
        }))
        scenarios.append(("missing Content-Type accepts only a fully completed SSE reply", {
            let reply = MockReply(mime: nil, body: sse([#"{"type":"response.output_text.delta","delta":"三。 Three."}"#, completed]), chunkSize: 1)
            let probe = HTTPURLResponse(url: URL(string: SubscriptionContract.resource + "/responses")!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: [:])!
            try expect(probe.value(forHTTPHeaderField: "Content-Type") == nil && probe.mimeType == nil, "Fixture unexpectedly has a MIME type")
            let (client, session, vault) = fixture(reply)
            defer { session.invalidateAndCancel() }
            let answer = try await client.respond(model: "fixture-plan", instructions: "Use the selected language.", turns: [.init(role: "user", text: "1+2")])
            try expect(answer == "三。 Three.", "Headerless valid SSE did not complete")
            try expect(MockLedger.shared.snapshot().count == 1 && vault.invalidationCalls().isEmpty, "Headerless response retried or invalidated account")
        }))
        for endpoint in Endpoint.allCases {
            for status in [401, 403, 429, 500, 503] {
                scenarios.append(("\(endpoint.rawValue) HTTP \(status) has correct failure and zero retries", {
                    let (client, session, vault) = fixture(.init(status: status))
                    defer { session.invalidateAndCancel() }
                    do { try await endpoint.call(client); throw CheckFailure("HTTP error was accepted") }
                    catch let error as PlanError {
                        try expect(error == (status == 401 ? .reauthenticationRequired : .service("http_\(status)")), "Wrong HTTP error classification")
                    }
                    try expect(MockLedger.shared.snapshot().count == 1, "HTTP failure retried implicitly")
                    try expect(vault.token() == (status == 401 ? nil : "synthetic-old-token"), "Wrong account invalidation")
                    try expect(vault.invalidationCalls() == (status == 401 ? ["synthetic-old-token"] : []), "Invalidation did not match request token")
                }))
            }
            for failure in [URLError.Code.notConnectedToInternet, .timedOut] {
                scenarios.append(("\(endpoint.rawValue) \(failure == .timedOut ? "timeout" : "offline") does not retry or invalidate", {
                    let (client, session, vault) = fixture(.init(failure: failure))
                    defer { session.invalidateAndCancel() }
                    do { try await endpoint.call(client); throw CheckFailure("Transport failure was accepted") }
                    catch let error as URLError { try expect(error.code == failure, "Transport error was masked") }
                    try expect(MockLedger.shared.snapshot().count == 1 && vault.invalidationCalls().isEmpty, "Transport failure retried or invalidated account")
                }))
            }
            scenarios.append(("\(endpoint.rawValue) stale 401 cannot erase a newly selected account", {
                let vault = FixtureVault()
                MockLedger.shared.reset([.init(status: 401, beforeResponse: { vault.replace("synthetic-new-account-token") })])
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [OfflineURLProtocol.self]
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let client = ChatGPTPlanClient(session: session, tokenSupplier: { vault.token()! }, invalidateToken: { vault.discardIfMatching($0) })
                do { try await endpoint.call(client); throw CheckFailure("401 was accepted") }
                catch let error as PlanError { try expect(error == .reauthenticationRequired, "Wrong stale-401 result") }
                try expect(vault.token() == "synthetic-new-account-token" && vault.invalidationCalls() == ["synthetic-old-token"], "Late error erased or targeted new account")
                try expect(MockLedger.shared.snapshot().count == 1, "Stale 401 retried")
            }))
        }
        let streamFailures: [(String, MockReply, PlanError?)] = [
            ("wrong MIME", .init(mime: "application/json", body: sse([completed])), .malformedResponse),
            ("misleading explicit MIME", .init(mime: "application/json; note=text/event-stream", body: sse([#"{"type":"response.output_text.delta","delta":"must not pass"}"#, completed])), .malformedResponse),
            ("empty explicit MIME", .init(mime: "", body: sse([#"{"type":"response.output_text.delta","delta":"must not pass"}"#, completed])), .malformedResponse),
            ("missing MIME with plain JSON", .init(mime: nil, body: Data(#"{"type":"response.completed","response":{"status":"completed","output":[{"content":[{"type":"output_text","text":"not SSE"}]}]}}"#.utf8)), .incompleteStream),
            ("missing MIME with HTML", .init(mime: nil, body: Data("<!doctype html><html><body>Not an event stream.</body></html>".utf8)), .incompleteStream),
            ("missing MIME with empty body", .init(mime: nil, body: Data()), .incompleteStream),
            ("missing MIME with partial SSE", .init(mime: nil, body: sse([#"{"type":"response.output_text.delta","delta":"partial"}"#])), .incompleteStream),
            ("missing MIME with late quota failure", .init(mime: nil, body: sse([#"{"type":"response.output_text.delta","delta":"partial"}"#, #"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#])), .service("subscription_sharing_usage_limit_exceeded")),
            ("malformed SSE JSON", .init(body: sse(["{malformed", completed])), nil),
            ("empty stream", .init(body: Data()), .incompleteStream),
            ("completed but empty reply", .init(body: sse([completed])), .service("empty_reply")),
            ("EOF after partial text", .init(body: sse([#"{"type":"response.output_text.delta","delta":"partial"}"#])), .incompleteStream),
            ("explicit incomplete", .init(body: sse([#"{"type":"response.output_text.delta","delta":"partial"}"#, #"{"type":"response.incomplete"}"#])), .incompleteStream),
            ("late subscription quota failure", .init(body: sse([#"{"type":"response.output_text.delta","delta":"partial"}"#, #"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#])), .service("subscription_sharing_usage_limit_exceeded"))
        ]
        for (name, reply, expected) in streamFailures {
            scenarios.append(("real response stream rejects \(name) without output/retry", {
                let (client, session, vault) = fixture(reply)
                defer { session.invalidateAndCancel() }
                var caught: Error?
                do { try await Endpoint.responses.call(client) } catch { caught = error }
                try expect(caught != nil, "Broken SSE returned success")
                if let expected { try expect(caught as? PlanError == expected, "Wrong SSE error classification") }
                try expect(MockLedger.shared.snapshot().count == 1 && vault.invalidationCalls().isEmpty, "SSE failure retried or invalidated account")
            }))
        }
        scenarios.append(("timeout after streaming starts discards partial reply without retry", {
            let (client, session, vault) = fixture(.init(body: sse([#"{"type":"response.output_text.delta","delta":"partial"}"#]), trailingFailure: .timedOut))
            defer { session.invalidateAndCancel() }
            do { try await Endpoint.responses.call(client); throw CheckFailure("Interrupted transport returned a partial success") }
            catch let error as URLError { try expect(error.code == .timedOut, "Mid-stream timeout was masked") }
            try expect(MockLedger.shared.snapshot().count == 1 && vault.invalidationCalls().isEmpty, "Interrupted stream retried or invalidated account")
        }))
        scenarios.append(("malformed model catalog fails without fallback", {
            let (client, session, vault) = fixture(.init(mime: "application/json", body: Data(#"{"data":[]}"#.utf8)))
            defer { session.invalidateAndCancel() }
            do { _ = try await client.models(); throw CheckFailure("Wrong catalog schema was accepted") }
            catch let error as PlanError { try expect(error == .malformedResponse, "Wrong catalog error") }
            try expect(MockLedger.shared.snapshot().count == 1 && vault.invalidationCalls().isEmpty, "Bad catalog caused fallback")
        }))
        scenarios.append(("missing authorized credentials sends no HTTP request", {
            let (client, session, vault) = fixture(.init())
            defer { session.invalidateAndCancel() }
            vault.replace(nil)
            do { try await Endpoint.responses.call(client); throw CheckFailure("Missing token was accepted") }
            catch let error as PlanError { try expect(error == .reauthenticationRequired, "Wrong missing-token failure") }
            try expect(MockLedger.shared.snapshot().isEmpty, "Unauthenticated request escaped token supplier")
        }))
        do {
            for (name, scenario) in scenarios { try await scenario(); print("PASS: " + name) }
            print("PASS: \(scenarios.count) production ChatGPTPlanClient URLSession integration scenarios. Every request was intercepted by ephemeral Mock URLProtocol; no live network, Keychain, user tokens or model usage.")
        } catch {
            FileHandle.standardError.write(Data("FAIL: network integration: \(error)\n".utf8)); exit(1)
        }
    }
}
