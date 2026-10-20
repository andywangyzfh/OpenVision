import Foundation
import SubscriptionCore

struct PlanRegistration: Codable, Sendable { let clientID: String; let subject: String }
struct PendingPlanRegistration: Codable, Sendable { let clientID: String }

@MainActor
protocol AccountRegistrationStorage: AnyObject {
    func hostID() throws -> String?
    func saveHostID(_ value: String) throws
    func registration() throws -> PlanRegistration?
    func saveRegistration(_ value: PlanRegistration) throws
    func pendingRegistration() throws -> PendingPlanRegistration?
    func savePendingRegistration(_ value: PendingPlanRegistration) throws
    func clearPendingRegistration() throws
}

/// Host/client/pending metadata all use the same explicit namespace. Production keeps its
/// existing Keychain namespace; controller tests inject memory storage and never construct it.
@MainActor
final class KeychainAccountRegistrationStorage: AccountRegistrationStorage {
    private let service: String
    init(service: String = KeychainRecord.defaultService) { self.service = service }
    func hostID() throws -> String? { try KeychainRecord.read(String.self, key: "host-id-v1", service: service) }
    func saveHostID(_ value: String) throws { try KeychainRecord.write(value, key: "host-id-v1", service: service) }
    func registration() throws -> PlanRegistration? { try KeychainRecord.read(PlanRegistration.self, key: "chatgpt-registration-v1", service: service) }
    func saveRegistration(_ value: PlanRegistration) throws { try KeychainRecord.write(value, key: "chatgpt-registration-v1", service: service) }
    func pendingRegistration() throws -> PendingPlanRegistration? { try KeychainRecord.read(PendingPlanRegistration.self, key: "chatgpt-pending-registration-v1", service: service) }
    func savePendingRegistration(_ value: PendingPlanRegistration) throws { try KeychainRecord.write(value, key: "chatgpt-pending-registration-v1", service: service) }
    func clearPendingRegistration() throws { try KeychainRecord.delete(key: "chatgpt-pending-registration-v1", service: service) }
}

struct AccountAuthorizationResponse: Sendable {
    let attempt: SignInAttempt
    let query: [URLQueryItem]
}

/// Only effects are injected. ChatGPTAccountService still executes callback validation,
/// cancellation generations, registration checks, Store epoch and the final commit permit.
@MainActor
struct AccountCoordinatorDependencies {
    let store: @Sendable () -> ChatGPTSessionStore
    let metadata: any AccountRegistrationStorage
    let tokenRequest: @Sendable ([String: String]) async throws -> TokenReply
    let validated: @Sendable (TokenReply, String, String?) async throws -> PlanCredentials
    let authorization: (@MainActor (String, String?) async throws -> AccountAuthorizationResponse)?
    let cancelAuthorization: @MainActor () -> Void
    let notifications: NotificationCenter

    init(store: @escaping @Sendable () -> ChatGPTSessionStore,
         metadata: any AccountRegistrationStorage,
         tokenRequest: @escaping @Sendable ([String: String]) async throws -> TokenReply,
         validated: @escaping @Sendable (TokenReply, String, String?) async throws -> PlanCredentials,
         authorization: (@MainActor (String, String?) async throws -> AccountAuthorizationResponse)? = nil,
         cancelAuthorization: @escaping @MainActor () -> Void = {},
         notifications: NotificationCenter = .default) {
        self.store = store; self.metadata = metadata; self.tokenRequest = tokenRequest
        self.validated = validated; self.authorization = authorization
        self.cancelAuthorization = cancelAuthorization; self.notifications = notifications
    }

    static func live() -> Self {
        // Preserve lazy access: constructing the service must not initialize the shared
        // Store or inspect a user's Keychain records before an explicit account action.
        Self(store: { .shared }, metadata: KeychainAccountRegistrationStorage(),
             tokenRequest: { try await ChatGPTSessionStore.tokenRequest($0) },
             validated: { try await ChatGPTSessionStore.validated($0, clientID: $1, nonce: $2) })
    }
}
