import Foundation
import SubscriptionCore

/// No CLI check constructs default Keychain storage or ChatGPTSessionStore.shared.
final class MemoryPlanStorage: PlanCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PlanCredentials?
    private var writesFail = false
    private var readsFail = false
    private var deletesFail = false
    private var clears = 0
    private var saves = 0
    private var loads = 0
    init(_ initial: PlanCredentials?) { value = initial }
    func load() throws -> PlanCredentials? {
        lock.lock(); defer { lock.unlock() }; loads += 1
        if readsFail { throw PlanError.service("fixture_read_failed") }
        return value
    }
    func save(_ credentials: PlanCredentials) throws {
        lock.lock(); defer { lock.unlock() }
        if writesFail { throw PlanError.service("fixture_write_failed") }
        value = credentials; saves += 1
    }
    func clear() throws {
        lock.lock(); defer { lock.unlock() }; clears += 1
        if deletesFail { throw KeychainDeletionError(status: -25308) }
        value = nil
    }
    func failDeletes(_ enabled: Bool) { lock.lock(); deletesFail = enabled; lock.unlock() }
    func clearCount() -> Int { lock.lock(); defer { lock.unlock() }; return clears }
    func snapshot() -> PlanCredentials? { lock.lock(); defer { lock.unlock() }; return value }
    func loadCount() -> Int { lock.lock(); defer { lock.unlock() }; return loads }
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

func fixture(_ initial: PlanCredentials?, confirmedRevocation: Bool = true) async throws -> (ChatGPTSessionStore, MemoryPlanStorage, RefreshFixture, RevocationFixture) {
    let storage = MemoryPlanStorage(initial), refresh = RefreshFixture(), revoke = RevocationFixture(confirmed: confirmedRevocation)
    let store = ChatGPTSessionStore(storage: storage, refreshOperation: { try await refresh.refresh($0) }, revocationOperation: { await revoke.revoke($0) })
    if initial != nil { _ = try await resume(store) }
    return (store, storage, refresh, revoke)
}

final class MemoryRestorationMarker: PlanRestorationMarker, @unchecked Sendable {
    private let lock = NSLock()
    private var blocked = false
    private var blockFails = false
    private var allowFails = false
    private var readFails = false
    func isBlocked() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if readFails { throw CredentialCleanupError.restorationStateUnavailable }
        return blocked
    }
    func block() throws {
        lock.lock(); defer { lock.unlock() }
        if blockFails { throw CredentialCleanupError.restorationStateUnavailable }
        blocked = true
    }
    func allow() throws {
        lock.lock(); defer { lock.unlock() }
        if allowFails { throw CredentialCleanupError.restorationStateUnavailable }
        blocked = false
    }
    func failBlock(_ value: Bool) { lock.lock(); blockFails = value; lock.unlock() }
    func failAllow(_ value: Bool) { lock.lock(); allowFails = value; lock.unlock() }
    func failRead(_ value: Bool) { lock.lock(); readFails = value; lock.unlock() }
}

func protectedFixture(_ initial: PlanCredentials) async throws -> (ChatGPTSessionStore, MemoryPlanStorage, MemoryRestorationMarker, RefreshFixture, ProtectedPlanCredentialStorage) {
    let secrets = MemoryPlanStorage(initial), marker = MemoryRestorationMarker(), refresh = RefreshFixture()
    let storage = ProtectedPlanCredentialStorage(secrets: secrets, marker: marker)
    let store = ChatGPTSessionStore(storage: storage, refreshOperation: { try await refresh.refresh($0) }, revocationOperation: { _ in true })
    _ = try await resume(store)
    return (store, secrets, marker, refresh, storage)
}

/// Holds one synchronous durable write, forcing authorization calls to queue behind the real
/// actor's refresh commit. Only a test thread blocks; production has no semaphore dependency.
final class BlockingSaveStorage: PlanCredentialStorage, @unchecked Sendable {
    let base: MemoryPlanStorage
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var armed = false
    private var entered = false
    init(_ base: MemoryPlanStorage) { self.base = base }
    func load() throws -> PlanCredentials? { try base.load() }
    func save(_ credentials: PlanCredentials) throws {
        lock.lock(); let hold = armed; armed = false; if hold { entered = true }; lock.unlock()
        if hold { release.wait() }
        try base.save(credentials)
    }
    func clear() throws { try base.clear() }
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func isHolding() -> Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func resume() { release.signal() }
}

/// Test helper models the user's explicit Resume action; production init never performs it.
@discardableResult
func resume(_ store: ChatGPTSessionStore) async throws -> PlanAccountUIState {
    let epoch = await store.authorizationEpoch()
    return try await store.resumeSavedCredentials(expectedEpoch: epoch, authorization: PlanAuthorizationPermit())
}
