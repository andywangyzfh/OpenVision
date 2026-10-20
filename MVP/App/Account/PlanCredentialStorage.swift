import Foundation
import Security
import CryptoKit
import SubscriptionCore

/// Synchronous persistence keeps a refresh commit atomic within the session actor.
protocol PlanCredentialStorage: Sendable {
    func load() throws -> PlanCredentials?
    func save(_ credentials: PlanCredentials) throws
    func clear() throws
}

enum LocalCredentialCleanup: Equatable, Sendable {
    case notChecked
    case removed
    case blockedPendingDeletion(OSStatus?)
    case unsafeFailure(OSStatus?)
}

struct PlanAccountUIState: Sendable {
    let credentials: PlanCredentials?
    let cleanup: LocalCredentialCleanup
    let epoch: Int
}

enum RemoteRevocationStatus: Equatable, Sendable { case confirmed, notNeeded, unconfirmed }

struct SessionSignOutResult: Sendable {
    let local: LocalCredentialCleanup
    let remote: RemoteRevocationStatus
    var remoteRevoked: Bool { remote == .confirmed }
    var complete: Bool { local == .removed && remote != .unconfirmed }
}

/// A synchronous cancellation boundary for a queued authorization commit. No network or async
/// work is done under this lock; only the final durable credential/marker transaction is held.
final class PlanAuthorizationPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private var consumed = false
    func cancel() { lock.lock(); valid = false; lock.unlock() }
    func commit<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        guard valid && !consumed else { throw CancellationError() }
        let result = try operation()
        consumed = true
        return result
    }
}

struct KeychainDeletionError: Error, LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Keychain deletion failed (OSStatus \(status))." }
}

enum CredentialCleanupError: Error {
    case deletionFailed(restorationBlocked: Bool, status: OSStatus?)
    case restorationStateUnavailable
    var state: LocalCredentialCleanup {
        switch self {
        case .deletionFailed(let blocked, let status): return blocked ? .blockedPendingDeletion(status) : .unsafeFailure(status)
        case .restorationStateUnavailable: return .unsafeFailure(nil)
        }
    }
}

protocol PlanRestorationMarker: Sendable {
    func isBlocked() throws -> Bool
    func block() throws
    func allow() throws
}

/// Only two non-secret state values live here; no identifier, token or account data is written.
/// Missing/corrupt state fails closed, including after reinstall or an interrupted first login.
struct FilePlanRestorationMarker: PlanRestorationMarker {
    let fileURL: URL
    init(service: String, key: String, root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenVision/Authentication", isDirectory: true)
        let namespace = Data(SHA256.hash(data: Data((service + "\u{0}" + key).utf8))).map { String(format: "%02x", $0) }.joined()
        fileURL = base.appendingPathComponent(namespace + ".state")
    }
    func isBlocked() throws -> Bool {
        do { return try Data(contentsOf: fileURL) != Data("allowed\n".utf8) }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return true }
            throw CredentialCleanupError.restorationStateUnavailable
        }
    }
    func block() throws { try write("blocked\n") }
    func allow() throws { try write("allowed\n") }
    private func write(_ value: String) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data(value.utf8).write(to: fileURL, options: .atomic)
    }
}

/// A durable signed-out marker is committed before deleting a secret. Cold starts refuse to
/// load blocked records and retry their deletion; only an explicit, successfully saved login
/// can permit restoration again.
struct ProtectedPlanCredentialStorage: PlanCredentialStorage {
    let secrets: any PlanCredentialStorage
    let marker: any PlanRestorationMarker
    init(secrets: any PlanCredentialStorage, marker: any PlanRestorationMarker) { self.secrets = secrets; self.marker = marker }
    static func production() -> Self {
        let secrets = KeychainPlanCredentialStorage()
        return Self(secrets: secrets, marker: FilePlanRestorationMarker(service: secrets.service, key: secrets.key))
    }
    func load() throws -> PlanCredentials? {
        let blocked: Bool
        do { blocked = try marker.isBlocked() } catch { throw CredentialCleanupError.restorationStateUnavailable }
        if blocked {
            do { try secrets.clear() }
            catch { throw CredentialCleanupError.deletionFailed(restorationBlocked: true, status: (error as? KeychainDeletionError)?.status) }
            return nil
        }
        return try secrets.load()
    }
    func save(_ credentials: PlanCredentials) throws {
        try marker.block()
        try secrets.save(credentials)
        do { try marker.allow() }
        catch {
            // A failed allow must never reactivate a blocked session. Keep the marker blocked;
            // best-effort removal does not disguise the failed durable login commit.
            try? secrets.clear()
            throw CredentialCleanupError.restorationStateUnavailable
        }
    }
    func clear() throws {
        var blocked = false
        do { try marker.block(); blocked = true }
        catch { blocked = (try? marker.isBlocked()) == true }
        do { try secrets.clear() }
        catch { throw CredentialCleanupError.deletionFailed(restorationBlocked: blocked, status: (error as? KeychainDeletionError)?.status) }
    }
}

struct KeychainPlanCredentialStorage: PlanCredentialStorage {
    let service: String
    let key: String
    private let deleteOperation: @Sendable (String, String) throws -> Void
    init(service: String = KeychainRecord.defaultService, key: String = "chatgpt-plan-session-v1",
         deleteOperation: @escaping @Sendable (String, String) throws -> Void = { try KeychainRecord.delete(key: $0, service: $1) }) {
        self.service = service; self.key = key
        self.deleteOperation = deleteOperation
    }
    func load() throws -> PlanCredentials? { try KeychainRecord.read(PlanCredentials.self, key: key, service: service) }
    func save(_ credentials: PlanCredentials) throws { try KeychainRecord.write(credentials, key: key, service: service) }
    func clear() throws { try deleteOperation(key, service) }
}

enum KeychainRecord {
    static let defaultService = "org.openvision.bilingual-mvp"
    private static func query(_ key: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    static func read<T: Decodable>(_ type: T.Type, key: String, service: String = defaultService) throws -> T? {
        var request = query(key, service: service)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PlanError.service("keychain_read_failed") }
        return try JSONDecoder().decode(type, from: data)
    }
    static func write<T: Encodable>(_ value: T, key: String, service: String = defaultService) throws {
        let data = try JSONEncoder().encode(value)
        let base = query(key, service: service)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = base
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw PlanError.service("keychain_write_failed") }
        } else if status != errSecSuccess { throw PlanError.service("keychain_write_failed") }
    }
    static func delete(key: String, service: String = defaultService) throws {
        let status = SecItemDelete(query(key, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainDeletionError(status: status) }
    }
}
