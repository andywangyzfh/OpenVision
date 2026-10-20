#if os(iOS)
import Foundation
import Security
import SubscriptionCore
import XCTest

/// iOS-only real Keychain checks. Every service is a unique test namespace; no production
/// Keychain query, user credential or remote authorization is used.
final class KeychainStoreTests: XCTestCase {
    @MainActor
    func testColdStoreDoesNotReadSyntheticKeychainUntilExplicitResume() async throws {
        let namespace = "org.openvision.tests.explicit-resume." + UUID().uuidString
        let raw = KeychainPlanCredentialStorage(service: namespace)
        defer { try? raw.clear() }
        let credentials = PlanCredentials(clientID: "synthetic-client", subject: "synthetic-subject", label: "Test",
            accessToken: "synthetic-access", refreshToken: "synthetic-refresh", idToken: "synthetic-id",
            scopes: SubscriptionContract.scopes, expiresAt: Date().addingTimeInterval(3600))
        try raw.save(credentials)
        let counted = CountedKeychainStorage(raw)
        let store = ChatGPTSessionStore(storage: counted, refreshOperation: { _ in
            throw PlanError.service("test_must_not_refresh")
        }, revocationOperation: { _ in true })
        let cold = await store.uiState()
        XCTAssertNil(cold.credentials)
        XCTAssertEqual(cold.cleanup, .notChecked)
        XCTAssertEqual(counted.loadCount, 0)
        let resumed = try await store.resumeSavedCredentials(expectedEpoch: cold.epoch, authorization: PlanAuthorizationPermit())
        XCTAssertEqual(resumed.credentials?.subject, credentials.subject)
        XCTAssertEqual(counted.loadCount, 1)
    }
    @MainActor
    func testNamespacedKeychainCRUDIsolationAndDeviceOnlyAccessibility() throws {
        let first = "org.openvision.tests.keychain." + UUID().uuidString
        let second = "org.openvision.tests.keychain." + UUID().uuidString
        let key = "synthetic-session"
        defer {
            try? KeychainRecord.delete(key: key, service: first)
            try? KeychainRecord.delete(key: key, service: second)
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
        try KeychainRecord.delete(key: key, service: first)
        XCTAssertNil(try KeychainRecord.read(String.self, key: key, service: first))
        XCTAssertEqual(try KeychainRecord.read(String.self, key: key, service: second), "synthetic-second")
    }

    @MainActor
    func testActualStoreRestoresAndClearsOnlyItsNamespacedKeychainRecord() async throws {
        let service = "org.openvision.tests.account." + UUID().uuidString
        let storage = KeychainPlanCredentialStorage(service: service)
        defer { try? storage.clear() }
        let credentials = PlanCredentials(clientID: "synthetic-client", subject: "synthetic-subject", label: "Test",
            accessToken: "synthetic-access", refreshToken: "synthetic-refresh", idToken: "synthetic-id",
            scopes: SubscriptionContract.scopes, expiresAt: Date().addingTimeInterval(3600))
        try storage.save(credentials)
        let store = ChatGPTSessionStore(storage: storage, refreshOperation: { _ in
            throw PlanError.service("test_must_not_refresh")
        }, revocationOperation: { _ in true })
        let epoch = await store.authorizationEpoch()
        _ = try await store.resumeSavedCredentials(expectedEpoch: epoch, authorization: PlanAuthorizationPermit())
        let token = try await store.accessToken()
        let snapshot = await store.snapshot()
        XCTAssertEqual(token, credentials.accessToken)
        XCTAssertEqual(snapshot?.subject, credentials.subject)
        let revoked = await store.signOut()
        XCTAssertTrue(revoked.complete)
        XCTAssertNil(try storage.load())
        let signedOut = await store.snapshot()
        XCTAssertNil(signedOut)
    }

    func testInjectedKeychainDeleteFailureCannotRestoreSyntheticRecordAfterColdStart() async throws {
        let namespace = "org.openvision.tests.failed-cleanup." + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenVision-marker-" + UUID().uuidString)
        let key = "chatgpt-plan-session-v1"
        defer {
            try? KeychainRecord.delete(key: key, service: namespace)
            try? FileManager.default.removeItem(at: root)
        }
        let credentials = PlanCredentials(clientID: "synthetic-client", subject: "synthetic-subject", label: "Test",
            accessToken: "synthetic-access", refreshToken: "synthetic-refresh", idToken: "synthetic-id",
            scopes: SubscriptionContract.scopes, expiresAt: Date().addingTimeInterval(3600))
        let marker = FilePlanRestorationMarker(service: namespace, key: key, root: root)
        let failingSecrets = KeychainPlanCredentialStorage(service: namespace, key: key, deleteOperation: { _, _ in
            throw KeychainDeletionError(status: errSecInteractionNotAllowed)
        })
        let protected = ProtectedPlanCredentialStorage(secrets: failingSecrets, marker: marker)
        try protected.save(credentials)
        let store = ChatGPTSessionStore(storage: protected, refreshOperation: { _ in
            throw PlanError.service("test_must_not_refresh")
        }, revocationOperation: { _ in true })
        let epoch = await store.authorizationEpoch()
        _ = try await store.resumeSavedCredentials(expectedEpoch: epoch, authorization: PlanAuthorizationPermit())
        let result = await store.signOut()
        XCTAssertEqual(result.local, .blockedPendingDeletion(errSecInteractionNotAllowed))
        XCTAssertFalse(result.complete)
        XCTAssertNotNil(try KeychainRecord.read(PlanCredentials.self, key: key, service: namespace))
        let cold = ChatGPTSessionStore(storage: protected, refreshOperation: { _ in
            throw PlanError.service("test_must_not_refresh")
        }, revocationOperation: { _ in true })
        let blockedSnapshot = await cold.snapshot()
        XCTAssertNil(blockedSnapshot)
        let coldEpoch = await cold.authorizationEpoch()
        _ = try await cold.resumeSavedCredentials(expectedEpoch: coldEpoch, authorization: PlanAuthorizationPermit())
        let coldStatus = await cold.cleanupState()
        XCTAssertEqual(coldStatus, .blockedPendingDeletion(errSecInteractionNotAllowed))
        // A later cold start with a functioning Keychain deletion retries cleanup, never restore.
        let working = ProtectedPlanCredentialStorage(secrets: KeychainPlanCredentialStorage(service: namespace, key: key), marker: marker)
        let retried = ChatGPTSessionStore(storage: working, refreshOperation: { _ in
            throw PlanError.service("test_must_not_refresh")
        }, revocationOperation: { _ in true })
        let retryEpoch = await retried.authorizationEpoch()
        _ = try await retried.resumeSavedCredentials(expectedEpoch: retryEpoch, authorization: PlanAuthorizationPermit())
        let cleaned = await retried.snapshot()
        XCTAssertNil(cleaned)
        XCTAssertNil(try KeychainRecord.read(PlanCredentials.self, key: key, service: namespace))
        try KeychainRecord.delete(key: key, service: namespace) // not-found is idempotent success
    }
}

private final class CountedKeychainStorage: PlanCredentialStorage, @unchecked Sendable {
    private let raw: any PlanCredentialStorage
    private let lock = NSLock()
    private var reads = 0
    init(_ raw: any PlanCredentialStorage) { self.raw = raw }
    var loadCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func load() throws -> PlanCredentials? {
        lock.lock(); reads += 1; lock.unlock()
        return try raw.load()
    }
    func save(_ value: PlanCredentials) throws { try raw.save(value) }
    func clear() throws { try raw.clear() }
}
#endif
