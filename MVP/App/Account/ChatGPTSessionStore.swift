import Foundation
import Security
import SubscriptionCore

/// One app-owned account for the MVP; no access to Codex/ChatGPT caches or tokens.
actor ChatGPTSessionStore {
    static let shared = ChatGPTSessionStore()
    private var credentials: PlanCredentials?
    private var refreshTask: Task<PlanCredentials, Error>?
    private var refreshID: UUID?
    private var generation = 0
    private let key = "chatgpt-plan-session-v1"
    init() { credentials = try? KeychainRecord.read(PlanCredentials.self, key: "chatgpt-plan-session-v1") }
    func snapshot() -> PlanCredentials? { credentials }
    func save(_ value: PlanCredentials) throws {
        try KeychainRecord.write(value, key: key)
        refreshTask?.cancel(); refreshTask = nil; refreshID = nil
        generation += 1
        credentials = value
    }
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = credentials else { throw PlanError.reauthenticationRequired }
        try SubscriptionContract.validateScopes(current.scopes)
        if !forceRefresh && current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        if let task = refreshTask {
            let expectedGeneration = generation
            let updated = try await task.value
            guard generation == expectedGeneration else { throw CancellationError() }
            return updated.accessToken
        }
        guard let token = current.refreshToken, !token.isEmpty else {
            invalidate()
            throw PlanError.reauthenticationRequired
        }
        let expectedGeneration = generation
        let task = Task { () throws -> PlanCredentials in
            do {
                let result = try await Self.tokenRequest(["grant_type": "refresh_token", "client_id": current.clientID,
                    "refresh_token": token, "resource": SubscriptionContract.resource])
                let updated = try await Self.refreshed(current, reply: result)
                guard generation == expectedGeneration else { throw CancellationError() }
                // Every waiter awaits this same task, including durable persistence. A Keychain
                // failure must never hand another caller an unpersisted rotating credential.
                try KeychainRecord.write(updated, key: key)
                credentials = updated
                return updated
            } catch PlanError.reauthenticationRequired {
                if generation == expectedGeneration { invalidate() }
                throw PlanError.reauthenticationRequired
            }
        }
        let operationID = UUID()
        refreshTask = task; refreshID = operationID
        defer {
            if refreshID == operationID { refreshTask = nil; refreshID = nil }
        }
        let updated = try await task.value
        guard generation == expectedGeneration else { throw CancellationError() }
        return updated.accessToken
    }
    func invalidate() {
        generation += 1
        refreshTask?.cancel(); refreshTask = nil; refreshID = nil
        credentials = nil
        KeychainRecord.delete(key: key)
        NotificationCenter.default.post(name: .chatGPTReauthenticationRequired, object: nil)
    }
    func discardIfMatching(_ token: String) {
        guard credentials?.accessToken == token else { return }
        invalidate()
    }
    /// Stop requests first. A failed remote revoke still clears local credentials.
    func signOut() async -> Bool {
        generation += 1
        refreshTask?.cancel(); refreshTask = nil; refreshID = nil
        let old = credentials
        credentials = nil
        KeychainRecord.delete(key: key)
        guard let old, let refreshToken = old.refreshToken else { return true }
        do {
            guard let endpoint = try await IDTokenVerifier.discovery().revocation_endpoint else { return false }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["token": refreshToken, "token_type_hint": "refresh_token", "client_id": old.clientID])
            request.timeoutInterval = 15
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }
    static func tokenRequest(_ values: [String: String]) async throws -> TokenReply {
        var request = URLRequest(url: URL(string: SubscriptionContract.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(values); request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw PlanError.service("network_error") }
        guard (200...299).contains(status) else { throw SubscriptionContract.tokenError(status: status, data: data) }
        return try JSONDecoder().decode(TokenReply.self, from: data)
    }
    static func refreshed(_ current: PlanCredentials, reply: TokenReply) async throws -> PlanCredentials {
        let claims: [String: Any]?
        if let idToken = reply.id_token {
            claims = try await IDTokenVerifier.verify(idToken, clientID: current.clientID, nonce: nil)
        } else { claims = nil }
        return try current.refreshed(with: reply, signatureVerifiedClaims: claims)
    }
    static func validated(_ reply: TokenReply, clientID: String, nonce: String?, previousScopes: String? = nil) async throws -> PlanCredentials {
        guard let scopes = reply.scope ?? previousScopes, let idToken = reply.id_token, !idToken.isEmpty else { throw PlanError.invalidIdentity }
        try SubscriptionContract.validateScopes(scopes)
        guard reply.token_type.lowercased() == "bearer", !reply.access_token.isEmpty, reply.expires_in > 0 else { throw PlanError.invalidIdentity }
        let claims = try await IDTokenVerifier.verify(idToken, clientID: clientID, nonce: nonce)
        guard let subject = claims["sub"] as? String else { throw PlanError.invalidIdentity }
        return PlanCredentials(clientID: clientID, subject: subject, label: claims["email"] as? String ?? "ChatGPT account",
            accessToken: reply.access_token, refreshToken: reply.refresh_token, idToken: idToken, scopes: scopes,
            expiresAt: Date().addingTimeInterval(reply.expires_in))
    }
    static func form(_ values: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(values.sorted(by: { $0.key < $1.key }).map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
}

extension Notification.Name {
    static let chatGPTReauthenticationRequired = Notification.Name("OpenVision.ChatGPTReauthenticationRequired")
}

enum KeychainRecord {
    private static let service = "org.openvision.bilingual-mvp"
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    static func read<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PlanError.service("keychain_read_failed") }
        return try JSONDecoder().decode(type, from: data)
    }
    static func write<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        let base = query(key)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = base
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw PlanError.service("keychain_write_failed") }
        } else if status != errSecSuccess { throw PlanError.service("keychain_write_failed") }
    }
    static func delete(key: String) { SecItemDelete(query(key) as CFDictionary) }
}
