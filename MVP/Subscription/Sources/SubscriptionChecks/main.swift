import Foundation
import CryptoKit
import Security
import SubscriptionCore

// Runs the production contract and real cryptographic verification without XCTest or network.
var count = 0
func check(_ message: String, _ value: @autoclosure () throws -> Bool) throws {
    guard try value() else { fatalError("FAIL: " + message) }
    count += 1
}
func rejects(_ message: String, _ operation: () throws -> Void) {
    do { try operation(); fatalError("FAIL: " + message) } catch { count += 1 }
}
func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
func feed(_ payloads: [String]) throws -> String {
    var stream = ResponseStream()
    for payload in payloads { try stream.consume(line: "data: " + payload); try stream.consume(line: "") }
    return try stream.finish()
}

let attempt = SignInAttempt(hostID: "urn:uuid:test", port: 54321)
let values = Dictionary(uniqueKeysWithValues: URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
try check("new dynamic registration", values["client_id"] == "dynamic_agent_client")
try check("numeric loopback callback", values["redirect_uri"] == "http://127.0.0.1:54321/auth/callback")
try check("resource and plan scope", values["resource"] == SubscriptionContract.resource && values["scope"]!.contains("chatgpt.tokens.use.direct"))
try check("PKCE SHA256", values["code_challenge"] == Data(SHA256.hash(data: Data(attempt.verifier.utf8))).base64URL)
try check("fresh nonce and state", attempt.nonce != SignInAttempt(hostID: attempt.hostID, port: 54321).nonce)
let query = [URLQueryItem(name: "code", value: "code"), .init(name: "state", value: attempt.state), .init(name: "client_id", value: "oaiapp_test")]
try check("issued client retained", try attempt.callback(query).clientID == "oaiapp_test")
rejects("missing issued ID") { _ = try attempt.callback(Array(query.prefix(2))) }
rejects("bad state") { _ = try attempt.callback([.init(name: "code", value: "c"), .init(name: "state", value: "wrong")]) }
rejects("duplicate state") { _ = try attempt.callback(query + [.init(name: "state", value: attempt.state)]) }
rejects("consent declined") { _ = try attempt.callback([.init(name: "state", value: attempt.state), .init(name: "error", value: "access_denied")]) }
let returning = SignInAttempt(hostID: attempt.hostID, port: 54321, clientID: "oaiapp_test")
rejects("client substitution") { _ = try returning.callback([.init(name: "code", value: "c"), .init(name: "state", value: returning.state), .init(name: "client_id", value: "other")]) }
rejects("identity alone grants no usage") { try SubscriptionContract.validateScopes("openid profile email") }
try SubscriptionContract.validateScopes(SubscriptionContract.scopes); count += 1
try check("refresh omission preserved", SubscriptionContract.refreshToken(replacement: nil, previous: "old") == "old")
try check("refresh rotation retained", SubscriptionContract.refreshToken(replacement: "new", previous: "old") == "new")
try check("revoked session actionable", SubscriptionContract.tokenError(status: 400, data: try json(["error": "invalid_grant"])) == .reauthenticationRequired)

let payload = try SubscriptionContract.responseBody(model: "account-model", instructions: "用中文回答", turns: [PlanTurn(role: "user", text: "看看这个", imageJPEG: Data([1, 2, 3])), PlanTurn(role: "assistant", text: "好的")])
let body = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
try check("supported fields only", Set(body.keys) == Set(["model", "instructions", "input", "store", "stream"]))
try check("stream true store false", body["store"] as? Bool == false && body["stream"] as? Bool == true)
try check("JPEG embedded", String(decoding: payload, as: UTF8.self).contains("data:image"))
rejects("system role rejected") { _ = try SubscriptionContract.responseBody(model: "m", instructions: "", turns: [.init(role: "system", text: "no")]) }
let delta = #"{"type":"response.output_text.delta","delta":"你好 Hello"}"#
let done = #"{"type":"response.completed","response":{"status":"completed"}}"#
try check("bilingual complete stream", try feed([delta, done]) == "你好 Hello")
var rawStream = ResponseStream()
for byte in ("data: " + delta + "\r\n\r\ndata: " + done + "\r\n\r\n").utf8 { try rawStream.consume(byte: byte) }
try check("raw UTF8 bytes retain SSE boundaries", try rawStream.finish() == "你好 Hello")
rejects("EOF never counts as success") { _ = try feed([delta]) }
rejects("DONE marker alone insufficient") { _ = try feed([delta, "[DONE]"]) }
rejects("late quota error discards partial output") { _ = try feed([delta, #"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#]) }
rejects("incomplete discards partial output") { _ = try feed([delta, #"{"type":"response.incomplete"}"#]) }
rejects("malformed SSE rejected") { _ = try feed(["{oops", done]) }
let catalog = try json(["models": [["slug":"b", "display_name":"B", "visibility":"list", "input_modalities":["text", "image"]], ["slug":"hidden", "visibility":"hide"], ["slug":"text", "visibility":"list", "input_modalities":["text"]], ["slug":"a", "visibility":"list"]]])
try check("catalog order/filter", try SubscriptionContract.models(from: catalog).map(\.id) == ["b", "a"])

let claims: [String: Any] = ["iss": SubscriptionContract.issuer, "aud": "oaiapp_test", "sub": "local-test-user", "nonce": "nonce", "exp": Date().addingTimeInterval(120).timeIntervalSince1970]
let key = P256.Signing.PrivateKey()
let point = key.publicKey.x963Representation
let jwks = try json(["keys": [["kid": "test", "alg": "ES256", "kty": "EC", "crv": "P-256", "x": point[1..<33].base64URL, "y": point[33..<65].base64URL]]])
let header = try json(["kid": "test", "alg": "ES256"]).base64URL
let content = try json(claims).base64URL
let message = header + "." + content
let token = message + "." + (try key.signature(for: Data(message.utf8))).rawRepresentation.base64URL
try check("ES256 cryptographic signature verified", try IDTokenVerifier.verify(token, clientID: "oaiapp_test", nonce: "nonce", jwks: jwks)["sub"] as? String == "local-test-user")
rejects("nonce substitution") { _ = try IDTokenVerifier.verify(token, clientID: "oaiapp_test", nonce: "wrong", jwks: jwks) }
rejects("audience substitution") { _ = try IDTokenVerifier.verify(token, clientID: "other", nonce: "nonce", jwks: jwks) }
let tampered = header + "." + (try json(["iss": SubscriptionContract.issuer, "aud": "oaiapp_test", "sub": "attacker", "nonce": "nonce", "exp": Date().addingTimeInterval(120).timeIntervalSince1970])).base64URL + "." + token.split(separator: ".")[2]
rejects("tampered claims signature") { _ = try IDTokenVerifier.verify(tampered, clientID: "oaiapp_test", nonce: "nonce", jwks: jwks) }
rejects("expired identity") { try SubscriptionContract.validateClaims(claims, clientID: "oaiapp_test", nonce: "nonce", now: Date().addingTimeInterval(1000)) }

// Offline RS256 fixture has no usable private key or user data.
try check("RS256 cryptographic signature verified", try IDTokenVerifier.verify(RSAFixture.token, clientID: "oaiapp_test", nonce: "nonce", jwks: RSAFixture.jwks)["sub"] as? String == "local-test-user")
rejects("unknown signing key") { _ = try IDTokenVerifier.verify(RSAFixture.token, clientID: "oaiapp_test", nonce: "nonce", jwks: jwks) }
print("PASS: \(count) subscription contract, stream, refresh and cryptographic checks (no network or user tokens).")
