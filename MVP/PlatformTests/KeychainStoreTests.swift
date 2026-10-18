#if os(iOS)
import Foundation
import Security
import SubscriptionCore
import XCTest

/// iOS-only real Keychain checks. Every service is a unique test namespace; no production
/// Keychain query, user credential or remote authorization is used.
final class KeychainStoreTests: XCTestCase {
    @MainActor
    func testNamespacedKeychainCRUDIsolationAndDeviceOnlyAccessibility() throws {
        let first = "org.openvision.tests.keychain." + UUID().uuidString
        let second = "org.openvision.tests.keychain." + UUID().uuidString
        let key = "synthetic-session"
        defer {
            KeychainRecord.delete(key: key, service: first)
            KeychainRecord.delete(key: key, service: second)
        }
        XCTAssertNotEqual(first, KeychainRecord.defaultService)
        XCTAssertNotEqual(second, KeychainRecord.defaultService)
        XCTAssertNil(try KeychainRecord.read(String.self, key: key, service: first))
        try KeychainRecord.write("synthetic-first", key: key, service: first)
        try KeychainRecord.write("synthetic-second", key: key, service: second)
        XCTAssertEqual(try KeychainRecord.read(String.self, key: key, service: first), "synthetic-first")
        XCTAssertEqual(try KeychainRecord.read(String.self, key: key, service: second), "synthetic-second")
        try KeychainRecord.write("synthetic-updated", key: key, service: first)
        XCTAssertEqual(try KeychainRecord.read(String.self, key: key, service: first), "synthetic-updated")
        XCTAssertEqual(try KeychainRecord.read(String.self, key: key, service: second), "synthetic-second")
        var attributes: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: first, kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, &attributes)
        XCTAssertEqual(status, errSecSuccess)
        let values = try XCTUnwrap(attributes as? [String: Any])
        XCTAssertEqual(values[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        KeychainRecord.delete(key: key, service: first)
        XCTAssertNil(try KeychainRecord.read(String.self, key: key, service: first))
        XCTAssertEqual(try KeychainRecord.read(String.self, key: key, service: second), "synthetic-second")
    }

    @MainActor
    func testActualStoreRestoresAndClearsOnlyItsNamespacedKeychainRecord() async throws {
        let service = "org.openvision.tests.account." + UUID().uuidString
        let storage = KeychainPlanCredentialStorage(service: service)
        defer { storage.clear() }
        let credentials = PlanCredentials(clientID: "synthetic-client", subject: "synthetic-subject", label: "Test",
            accessToken: "synthetic-access", refreshToken: "synthetic-refresh", idToken: "synthetic-id",
            scopes: SubscriptionContract.scopes, expiresAt: Date().addingTimeInterval(3600))
        try storage.save(credentials)
        let store = ChatGPTSessionStore(storage: storage, refreshOperation: { _ in
            throw PlanError.service("test_must_not_refresh")
        }, revocationOperation: { _ in true })
        let token = try await store.accessToken()
        let snapshot = await store.snapshot()
        XCTAssertEqual(token, credentials.accessToken)
        XCTAssertEqual(snapshot?.subject, credentials.subject)
        let revoked = await store.signOut()
        XCTAssertTrue(revoked)
        XCTAssertNil(try storage.load())
        let signedOut = await store.snapshot()
        XCTAssertNil(signedOut)
    }
}
#endif
