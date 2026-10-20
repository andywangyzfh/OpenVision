import CryptoKit
import Foundation
import XCTest
@testable import SubscriptionCore

/// All URLs are intercepted. These exercise the actual metadata verifier and production
/// URLSession redirect delegate without contacting an issuer or using any account credentials.
final class IdentityTransportTests: XCTestCase {
    private let discoveryURL = SubscriptionContract.issuer + "/.well-known/openid-configuration"
    private let keysURL = SubscriptionContract.issuer + "/fixture-keys"

    func testTrustedDiscoveryAndSignedIdentityUseOnlyExpectedEndpoints() async throws {
        let fixture = IdentityHTTPFixture()
        let identity = try signedIdentity()
        fixture.set(discoveryURL, .response(200, try metadata()))
        fixture.set(keysURL, .response(200, identity.jwks))
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let claims = try await IDTokenVerifier.verify(identity.token, clientID: "synthetic-client", nonce: "synthetic-nonce", session: session)
        XCTAssertEqual(claims["sub"] as? String, "synthetic-subject")
        XCTAssertEqual(fixture.requests.map { $0.url!.absoluteString }, [discoveryURL, keysURL])
        XCTAssertTrue(fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    func testUntrustedDiscoveryNeverFetchesAdvertisedEndpoints() async throws {
        let variants: [[String: String]] = [
            ["issuer": "https://other.invalid"],
            ["jwks_uri": "https://other.invalid/keys"],
            ["jwks_uri": "http://auth.openai.com/keys"],
            ["jwks_uri": "https://user:password@auth.openai.com/keys"],
            ["jwks_uri": "https://auth.openai.com:444/keys"],
            ["jwks_uri": "https://auth.openai.com/keys#fragment"],
            ["revocation_endpoint": "https://other.invalid/revoke"],
            ["revocation_endpoint": "http://auth.openai.com/revoke"],
            ["revocation_endpoint": "https://auth.openai.com:444/revoke"],
            ["revocation_endpoint": "https://user@auth.openai.com/revoke"]
        ]
        for variant in variants {
            let fixture = IdentityHTTPFixture()
            fixture.set(discoveryURL, .response(200, try metadata(overrides: variant)))
            let session = fixture.session()
            defer { session.invalidateAndCancel(); fixture.remove() }
            do {
                _ = try await IDTokenVerifier.verify("synthetic-invalid-token", clientID: "synthetic-client", nonce: nil, session: session)
                XCTFail("Untrusted metadata accepted: \(variant)")
            } catch { XCTAssertEqual(error as? PlanError, .invalidIdentity, "\(variant)") }
            XCTAssertEqual(fixture.requests.map { $0.url!.absoluteString }, [discoveryURL])
        }
    }

    func testFailedDiscoveryAndJWKSHaveNoImplicitRetryAndExplicitRetryRecovers() async throws {
        let fixture = IdentityHTTPFixture()
        let identity = try signedIdentity()
        fixture.set(discoveryURL, .response(503, Data("synthetic unavailable".utf8)))
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        do { _ = try await IDTokenVerifier.discovery(session: session); XCTFail("503 accepted") }
        catch { XCTAssertEqual(error as? PlanError, .invalidIdentity) }
        XCTAssertEqual(fixture.requests.count, 1)
        fixture.set(discoveryURL, .response(200, try metadata()))
        fixture.set(keysURL, .response(503, Data()))
        do {
            _ = try await IDTokenVerifier.verify(identity.token, clientID: "synthetic-client", nonce: "synthetic-nonce", session: session)
            XCTFail("JWKS failure accepted")
        } catch { XCTAssertEqual(error as? PlanError, .invalidIdentity) }
        XCTAssertEqual(fixture.requests.count, 3)
        fixture.set(keysURL, .response(200, identity.jwks))
        let claims = try await IDTokenVerifier.verify(identity.token, clientID: "synthetic-client", nonce: "synthetic-nonce", session: session)
        XCTAssertEqual(claims["sub"] as? String, "synthetic-subject")
        XCTAssertEqual(fixture.requests.count, 5)
    }

    func testRedirectDelegateRejectsSameOriginCrossOriginAndDowngrade() async throws {
        let targets = ["https://auth.openai.com/another-path", "https://other.invalid/collect", "http://auth.openai.com/collect"]
        let session = PlanHTTPTransport.makeSession()
        defer { session.invalidateAndCancel() }
        let delegate = try XCTUnwrap(session.delegate as? URLSessionTaskDelegate)
        for status in [301, 302, 303, 307, 308] {
            for target in targets {
                var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
                request.httpMethod = "POST"
                request.httpBody = Data("refresh_token=synthetic-refresh".utf8)
                request.setValue("Bearer synthetic-access", forHTTPHeaderField: "Authorization")
                let task = session.dataTask(with: request)
                let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": target]))
                var redirected = request; redirected.url = URL(string: target)!
                let allowed = await withCheckedContinuation { continuation in
                    delegate.urlSession?(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) {
                        continuation.resume(returning: $0)
                    }
                }
                XCTAssertNil(allowed, "\(status): \(target)")
                task.cancel() // Never resume this task: this test invokes the installed policy only.
            }
        }
    }

    func testOriginalMetadata3xxIsRejectedAndExplicitRetryRecovers() async throws {
        let fixture = IdentityHTTPFixture()
        fixture.set(discoveryURL, .response(307, Data()))
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        do { _ = try await IDTokenVerifier.discovery(session: session); XCTFail("3xx accepted") }
        catch { XCTAssertEqual(error as? PlanError, .invalidIdentity) }
        XCTAssertEqual(fixture.requests.map { $0.url!.absoluteString }, [discoveryURL])
        fixture.set(discoveryURL, .response(200, try metadata()))
        let retried = try await IDTokenVerifier.discovery(session: session)
        XCTAssertEqual(retried.issuer, SubscriptionContract.issuer)
        XCTAssertEqual(fixture.requests.map { $0.url!.absoluteString }, [discoveryURL, discoveryURL])
    }

    #if os(macOS)
    func testRealLoopbackRedirectsNeverForwardSyntheticBearerOrRefreshBody() async throws {
        let target = try IdentityRedirectServer(status: 200)
        let targetPort = try await target.start()
        defer { target.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3; configuration.timeoutIntervalForResource = 3
        let session = PlanHTTPTransport.makeSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for status in [301, 302, 303, 307, 308] {
            let source = try IdentityRedirectServer(status: status, location: "http://127.0.0.1:\(targetPort)/must-not-receive")
            let sourcePort = try await source.start()
            defer { source.stop() }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(sourcePort)/synthetic-token")!)
            request.httpMethod = "POST"
            request.setValue("Bearer synthetic-access", forHTTPHeaderField: "Authorization")
            request.httpBody = Data("refresh_token=synthetic-refresh".utf8)
            let (_, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
            XCTAssertEqual(source.received.count, 1)
            XCTAssertEqual(source.received.first?.authorization, "Bearer synthetic-access")
            XCTAssertEqual(source.received.first?.body, request.httpBody)
            XCTAssertEqual(target.received.count, 0, "Redirect forwarded credentials: \(status)")
        }
    }
    #endif

    private func metadata(overrides: [String: String] = [:]) throws -> Data {
        var value = ["issuer": SubscriptionContract.issuer, "jwks_uri": keysURL,
                     "revocation_endpoint": SubscriptionContract.issuer + "/fixture-revoke"]
        value.merge(overrides) { _, newer in newer }
        return try JSONSerialization.data(withJSONObject: value)
    }

    private func signedIdentity() throws -> (token: String, jwks: Data) {
        let key = P256.Signing.PrivateKey()
        let point = key.publicKey.x963Representation
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "synthetic-key", "alg": "ES256", "kty": "EC", "crv": "P-256",
            "x": point[1..<33].base64URL, "y": point[33..<65].base64URL]]])
        let header = try JSONSerialization.data(withJSONObject: ["kid": "synthetic-key", "alg": "ES256"]).base64URL
        let claims = try JSONSerialization.data(withJSONObject: ["iss": SubscriptionContract.issuer, "aud": "synthetic-client", "sub": "synthetic-subject",
            "nonce": "synthetic-nonce", "exp": Date().addingTimeInterval(300).timeIntervalSince1970]).base64URL
        let message = header + "." + claims
        return (message + "." + (try key.signature(for: Data(message.utf8))).rawRepresentation.base64URL, jwks)
    }
}

private final class IdentityHTTPFixture: @unchecked Sendable {
    enum Reply { case response(Int, Data) }
    let id = UUID().uuidString
    private let lock = NSLock()
    private var routes: [String: Reply] = [:]
    private var recorded: [URLRequest] = []
    private static let registry = IdentityFixtureRegistry()
    func set(_ url: String, _ reply: Reply) { lock.lock(); defer { lock.unlock() }; routes[url] = reply }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func reply(for request: URLRequest) -> Reply? {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        return routes[request.url?.absoluteString ?? ""]
    }
    func session() -> URLSession {
        Self.registry.add(self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2; configuration.timeoutIntervalForResource = 2
        configuration.protocolClasses = [IdentityURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Identity-Fixture": id]
        return PlanHTTPTransport.makeSession(configuration: configuration)
    }
    func remove() { Self.registry.remove(id) }
    static func fixture(for request: URLRequest) -> IdentityHTTPFixture? {
        registry.get(request.value(forHTTPHeaderField: "X-Identity-Fixture") ?? "")
    }
}

private final class IdentityFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: IdentityHTTPFixture] = [:]
    func add(_ fixture: IdentityHTTPFixture) { lock.lock(); defer { lock.unlock() }; values[fixture.id] = fixture }
    func get(_ id: String) -> IdentityHTTPFixture? { lock.lock(); defer { lock.unlock() }; return values[id] }
    func remove(_ id: String) { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: id) }
}

private final class IdentityURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true } // No unmatched request may escape to the network.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let fixture = IdentityHTTPFixture.fixture(for: request), let reply = fixture.reply(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        switch reply {
        case .response(let status, let data):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)

        }
    }
}
