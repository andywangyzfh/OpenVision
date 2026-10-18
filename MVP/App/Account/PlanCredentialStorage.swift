import Foundation
import Security
import SubscriptionCore

/// Synchronous persistence keeps a refresh commit atomic within the session actor.
protocol PlanCredentialStorage: Sendable {
    func load() throws -> PlanCredentials?
    func save(_ credentials: PlanCredentials) throws
    func clear()
}

struct KeychainPlanCredentialStorage: PlanCredentialStorage {
    let service: String
    let key: String
    init(service: String = KeychainRecord.defaultService, key: String = "chatgpt-plan-session-v1") {
        self.service = service; self.key = key
    }
    func load() throws -> PlanCredentials? { try KeychainRecord.read(PlanCredentials.self, key: key, service: service) }
    func save(_ credentials: PlanCredentials) throws { try KeychainRecord.write(credentials, key: key, service: service) }
    func clear() { KeychainRecord.delete(key: key, service: service) }
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
    static func delete(key: String, service: String = defaultService) { SecItemDelete(query(key, service: service) as CFDictionary) }
}
