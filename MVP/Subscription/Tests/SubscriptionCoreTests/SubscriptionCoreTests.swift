import Foundation
import XCTest
@testable import SubscriptionCore

final class SubscriptionCoreTests: XCTestCase {
    func testAuthorizationAndPKCEContract() throws {
        let a = SignInAttempt(hostID: "urn:uuid:test", port: 1455)
        let values = Dictionary(uniqueKeysWithValues: URLComponents(url: a.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(values["client_id"], "dynamic_agent_client")
        XCTAssertEqual(values["redirect_uri"], "http://127.0.0.1:1455/auth/callback")
        XCTAssertEqual(values["resource"], "https://api.openai.com/v1")
        XCTAssertNotEqual(values["code_challenge"], a.verifier)
        XCTAssertNotEqual(a.state, SignInAttempt(hostID: a.hostID, port: 1455).state)
        XCTAssertThrowsError(try a.callback([.init(name: "code", value: "code"), .init(name: "state", value: "wrong")]))
        XCTAssertThrowsError(try a.callback([.init(name: "code", value: "code"), .init(name: "state", value: a.state)]))
        let result = try a.callback([.init(name: "code", value: "code"), .init(name: "state", value: a.state), .init(name: "client_id", value: "oaiapp_test")])
        XCTAssertEqual(result.clientID, "oaiapp_test")
    }
    func testReauthorizationCannotSwitchClient() {
        let a = SignInAttempt(hostID: "host", port: 1455, clientID: "oaiapp_expected")
        XCTAssertThrowsError(try a.callback([.init(name: "code", value: "c"), .init(name: "state", value: a.state), .init(name: "client_id", value: "oaiapp_other")]))
        XCTAssertThrowsError(try a.callback([.init(name: "state", value: a.state), .init(name: "state", value: a.state), .init(name: "code", value: "c")]))
    }
    func testScopesAndIdentityFailClosed() throws {
        XCTAssertThrowsError(try SubscriptionContract.validateScopes("openid profile email"))
        try SubscriptionContract.validateScopes(SubscriptionContract.scopes)
        let claims: [String: Any] = ["iss": SubscriptionContract.issuer, "aud": "oaiapp_test", "sub": "s", "exp": Date().addingTimeInterval(60).timeIntervalSince1970, "nonce": "n"]
        try SubscriptionContract.validateClaims(claims, clientID: "oaiapp_test", nonce: "n")
        XCTAssertThrowsError(try SubscriptionContract.validateClaims(claims, clientID: "other", nonce: "n"))
        XCTAssertThrowsError(try SubscriptionContract.validateClaims(claims, clientID: "oaiapp_test", nonce: "wrong"))
        XCTAssertThrowsError(try SubscriptionContract.validateClaims(claims, clientID: "oaiapp_test", nonce: "n", now: Date().addingTimeInterval(100)))
    }
    func testBodyTextImageAndNoUnsupportedOrPaidFields() throws {
        let data = try SubscriptionContract.responseBody(model: "test", instructions: "中文", turns: [.init(role: "user", text: "看看这个", imageJPEG: Data([1,2,3]))])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set(["model", "instructions", "input", "store", "stream"]))
        XCTAssertEqual(body["store"] as? Bool, false); XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("data:image"))
        XCTAssertThrowsError(try SubscriptionContract.responseBody(model: "test", instructions: "", turns: [.init(role: "system", text: "no")]))
    }
    func testStreamOnlySucceedsAfterTerminalCompleted() throws {
        var stream = ResponseStream()
        try stream.consume(line: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"你好\"}")
        try stream.consume(line: "")
        XCTAssertThrowsError(try stream.finish())
        try stream.consume(line: "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}")
        XCTAssertEqual(try stream.finish(), "你好")
    }
    func testStreamRejectsLateUsageFailureAndIncomplete() throws {
        for type in ["response.failed", "response.incomplete", "error"] {
            var stream = ResponseStream()
            try stream.consume(line: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}")
            try stream.consume(line: "")
            try stream.consume(line: "data: {\"type\":\"\(type)\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}")
            XCTAssertThrowsError(try stream.finish())
        }
    }
    func testModelsPreserveServerOrderingAndFilter() throws {
        let data = Data(#"{"models":[{"slug":"b","display_name":"B","visibility":"list","input_modalities":["text","image"]},{"slug":"hidden","visibility":"hide"},{"slug":"text","visibility":"list","input_modalities":["text"]},{"slug":"a","visibility":"list"}]}"#.utf8)
        XCTAssertEqual(try SubscriptionContract.models(from: data).map(\.id), ["b", "a"])
    }
}
