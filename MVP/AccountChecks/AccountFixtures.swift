import Foundation
import SubscriptionCore

/// No CLI check constructs default Keychain storage or ChatGPTSessionStore.shared.
final class MemoryPlanStorage: PlanCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PlanCredentials?
    private var writesFail = false
    private var readsFail = false
    private var saves = 0
    init(_ initial: PlanCredentials?) { value = initial }
    func load() throws -> PlanCredentials? {
        lock.lock(); defer { lock.unlock() }
        if readsFail { throw PlanError.service("fixture_read_failed") }
        return value
    }
    func save(_ credentials: PlanCredentials) throws {
        lock.lock(); defer { lock.unlock() }
        if writesFail { throw PlanError.service("fixture_write_failed") }
        value = credentials; saves += 1
    }
    func clear() { lock.lock(); value = nil; lock.unlock() }
    func snapshot() -> PlanCredentials? { lock.lock(); defer { lock.unlock() }; return value }
    func saveCount() -> Int { lock.lock(); defer { lock.unlock() }; return saves }
    func failWrites(_ enabled: Bool) { lock.lock(); writesFail = enabled; lock.unlock() }
    func failReads(_ enabled: Bool) { lock.lock(); readsFail = enabled; lock.unlock() }
}

/// Ignores Task cancellation to exercise the production actor's generation and operation IDs.
actor RefreshFixture {
    private var calls: [PlanCredentials] = []
    private var waiters: [Int: CheckedContinuation<PlanCredentials, Error>] = [:]
    func refresh(_ credentials: PlanCredentials) async throws -> PlanCredentials {
        let index = calls.count
        calls.append(credentials)
        return try await withCheckedThrowingContinuation { waiters[index] = $0 }
    }
    func count() -> Int { calls.count }
    func resolve(_ index: Int, _ result: Result<PlanCredentials, Error>) {
        waiters.removeValue(forKey: index)?.resume(with: result)
    }
}

actor RevocationFixture {
    private var calls: [PlanCredentials] = []
    let confirmed: Bool
    init(confirmed: Bool = true) { self.confirmed = confirmed }
    func revoke(_ credentials: PlanCredentials) -> Bool { calls.append(credentials); return confirmed }
    func count() -> Int { calls.count }
}

func credential(_ identity: String = "old", fresh: Bool = false, refresh: String? = "synthetic-refresh-old") -> PlanCredentials {
    .init(clientID: "client-" + identity, subject: "subject-" + identity, label: "Synthetic fixture",
        accessToken: "synthetic-access-" + identity, refreshToken: refresh, idToken: "synthetic-id-" + identity,
        scopes: SubscriptionContract.scopes, expiresAt: Date().addingTimeInterval(fresh ? 3600 : -60))
}

func updated(_ old: PlanCredentials, suffix: String = "rotated") -> PlanCredentials {
    var next = old
    next.accessToken = old.accessToken + "-" + suffix
    next.refreshToken = "synthetic-refresh-" + suffix
    next.expiresAt = Date().addingTimeInterval(3600)
    return next
}

func fixture(_ initial: PlanCredentials?, confirmedRevocation: Bool = true) -> (ChatGPTSessionStore, MemoryPlanStorage, RefreshFixture, RevocationFixture) {
    let storage = MemoryPlanStorage(initial), refresh = RefreshFixture(), revoke = RevocationFixture(confirmed: confirmedRevocation)
    let store = ChatGPTSessionStore(storage: storage, refreshOperation: { try await refresh.refresh($0) }, revocationOperation: { await revoke.revoke($0) })
    return (store, storage, refresh, revoke)
}
