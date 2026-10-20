import Foundation
import SubscriptionCore

struct BenchmarkAuthorizationAttempt: Sendable {
    let generation: Int
    let storeEpoch: Int
    let permit: PlanAuthorizationPermit
}

/// A Mac-only coordinator over the same Store commit permit used by the iPhone app.
/// Cancellation invalidates permission synchronously, before any asynchronous cleanup.
@MainActor
final class BenchmarkLifecycle {
    enum Phase: Equatable { case idle, authorizing, ready, running, cleaning, closed }
    private(set) var phase: Phase = .idle
    private(set) var generation = 0
    private(set) var models: [BenchmarkModel] = []
    private(set) var billingConfirmed = false
    private var permit: PlanAuthorizationPermit?
    private var cleanupTask: (id: UUID, task: Task<SessionSignOutResult, Never>)?
    let store: ChatGPTSessionStore
    init(store: ChatGPTSessionStore) { self.store = store }
    var canAuthorize: Bool { phase == .idle }
    var authenticated: Bool { phase == .ready || phase == .running }
    var canRun: Bool { phase == .ready && models.count == 3 && billingConfirmed }
    func setBillingConfirmed(_ value: Bool) { billingConfirmed = authenticated && value }

    func beginAuthorization() async throws -> BenchmarkAuthorizationAttempt {
        guard canAuthorize else { throw CancellationError() }
        generation += 1; phase = .authorizing
        let owner = generation, permit = PlanAuthorizationPermit()
        self.permit = permit
        let epoch = await store.authorizationEpoch()
        try ensureCurrent(owner)
        return .init(generation: owner, storeEpoch: epoch, permit: permit)
    }
    func ensureCurrent(_ owner: Int) throws {
        try Task.checkCancellation()
        guard owner == generation, phase != .cleaning, phase != .closed, phase != .idle else { throw CancellationError() }
    }
    func commit(_ credentials: PlanCredentials, attempt: BenchmarkAuthorizationAttempt) async throws {
        try ensureCurrent(attempt.generation)
        try await store.save(credentials, expectedEpoch: attempt.storeEpoch, authorization: attempt.permit)
        try ensureCurrent(attempt.generation)
    }
    func markReady(_ attempt: BenchmarkAuthorizationAttempt, models: [BenchmarkModel]) throws {
        try ensureCurrent(attempt.generation)
        guard phase == .authorizing else { throw CancellationError() }
        guard models.count == 3, Set(models.map(\.slug)).count == 3 else { throw PlanError.service("catalog_candidates_unavailable") }
        self.models = models; billingConfirmed = false; phase = .ready
    }
    func beginRun() throws -> Int {
        guard canRun else { throw CancellationError() }
        phase = .running
        return generation
    }
    /// Call before cancelling tasks or awaiting the Store. Old queued commits then fail even
    /// when an upstream token/JWKS operation does not cooperate with Task cancellation.
    @discardableResult func invalidate(closing: Bool = false) -> Int {
        generation += 1; permit?.cancel(); permit = nil
        models = []; billingConfirmed = false
        phase = closing || phase == .closed ? .closed : .cleaning
        return generation
    }
    func finishCleanup(owner: Int) async -> SessionSignOutResult {
        // An obsolete cleanup must never erase a later authorized session.
        guard owner == generation else { return .init(local: .notChecked, remote: .unconfirmed) }
        // All overlapping cancel/close paths share one cleanup. No obsolete queued signOut
        // can remain behind and erase a later login after the UI becomes retryable.
        let pending: (id: UUID, task: Task<SessionSignOutResult, Never>)
        if let cleanupTask { pending = cleanupTask }
        else {
            let store = store
            pending = (UUID(), Task { await store.signOut() })
            cleanupTask = pending
        }
        let result = await pending.task.value
        if cleanupTask?.id == pending.id { cleanupTask = nil }
        if owner == generation, phase == .cleaning { phase = .idle }
        return result
    }
    func owns(_ owner: Int) -> Bool { owner == generation }
}

struct BenchmarkPersistenceFailure: Error {}

/// Network collection and persistence are separate. A failed write retains exactly one row
/// in memory and never manufactures a second "network failure" for the same request index.
@MainActor
final class BenchmarkRowLedger {
    private(set) var rows: [BenchmarkRow] = []
    private(set) var persistedCount = 0
    func reset() { rows = []; persistedCount = 0 }
    func append(_ row: BenchmarkRow, persist: ([BenchmarkRow]) throws -> Void) throws {
        guard row.index == rows.count + 1 else { throw BenchmarkPersistenceFailure() }
        rows.append(row)
        do { try persist(rows); persistedCount = rows.count }
        catch { throw BenchmarkPersistenceFailure() }
    }
}

func benchmarkCleanupMessage(_ result: SessionSignOutResult) -> String {
    let local: String
    switch result.local {
    case .removed: local = "本工具内存凭据已清除 / Tool memory credentials cleared."
    case .notChecked: local = "尚未确认本工具凭据清理 / Tool credential cleanup not confirmed."
    case .blockedPendingDeletion: local = "本机恢复已阻止，凭据删除尚待重试 / Restoration blocked; deletion pending."
    case .unsafeFailure: local = "本工具凭据清理失败，不能宣称安全退出 / Credential cleanup failed; safe exit not confirmed."
    }
    let remote: String
    switch result.remote {
    case .confirmed: remote = "远端撤销已确认 / Remote revocation confirmed."
    case .notNeeded: remote = "本次无可撤销刷新令牌；未声称撤销整个账号 / No refresh token to revoke; account-wide revocation not claimed."
    case .unconfirmed: remote = "远端撤销未确认；可在 ChatGPT 设置撤销本工具授权 / Remote revocation unconfirmed; disconnect this tool in ChatGPT settings."
    }
    return local + " " + remote
}
