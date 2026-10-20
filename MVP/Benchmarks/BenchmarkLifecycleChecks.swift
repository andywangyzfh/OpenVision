import Foundation
import SubscriptionCore

private struct LifecycleCheckFailure: Error { let label: String }
@MainActor private func require(_ value: Bool, _ label: String) throws {
    guard value else { throw LifecycleCheckFailure(label: label) }
}
private func fixtureCredentials(_ token: String) -> PlanCredentials {
    .init(clientID: "synthetic-mac-client", subject: "synthetic-subject", label: "synthetic account",
          accessToken: token, refreshToken: "synthetic-refresh", idToken: "synthetic-id-token",
          scopes: SubscriptionContract.scopes, expiresAt: Date().addingTimeInterval(3600))
}
private let fixtureModels = ["fixture-a", "fixture-b", "fixture-c"].map { BenchmarkModel(slug: $0, modalities: ["text", "image"]) }
private actor RevocationGate {
    private(set) var calls = 0
    private var reply: CheckedContinuation<Bool, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func revoke() async -> Bool {
        calls += 1
        return await withCheckedContinuation { continuation in reply = continuation; started?.resume(); started = nil }
    }
    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { reply?.resume(returning: false); reply = nil }
}

@MainActor
enum BenchmarkLifecycleChecks {
    private static func fixture() -> (BenchmarkLifecycle, ChatGPTSessionStore) {
        let store = ChatGPTSessionStore(storage: BenchmarkMemoryStorage(), revocationOperation: { _ in false })
        return (BenchmarkLifecycle(store: store), store)
    }
    private static func ready(_ lifecycle: BenchmarkLifecycle, token: String = "synthetic-ready") async throws -> BenchmarkAuthorizationAttempt {
        let attempt = try await lifecycle.beginAuthorization()
        try await lifecycle.commit(fixtureCredentials(token), attempt: attempt)
        try lifecycle.markReady(attempt, models: fixtureModels)
        lifecycle.setBillingConfirmed(true)
        return attempt
    }
    private static func row(_ index: Int, outcome: String = "success") -> BenchmarkRow {
        .init(index: index, model: "fixture-a", fixture: "cn_practical", repetition: 0, connection: "synthetic",
              outcome: outcome, errorCategory: outcome == "failure" ? "url_-1009" : nil,
              answer: outcome == "success" ? "public synthetic answer" : nil, checks: [:], callElapsedNanoseconds: 1, observations: [])
    }
    static func run() async throws {
        let scenarios: [(String, @MainActor () async throws -> Void)] = [
            ("cold tool does not activate any saved account", {
                let (lifecycle, store) = fixture()
                try require(lifecycle.canAuthorize && !lifecycle.authenticated && !lifecycle.canRun, "Cold controls not idle")
                try require(await store.snapshot() == nil, "Cold store has credentials")
            }),
            ("pre-login billing confirmation cannot authorize a new account's run", {
                let (lifecycle, _) = fixture()
                lifecycle.setBillingConfirmed(true)
                try require(!lifecycle.billingConfirmed, "Cold state accepted billing attestation")
                let attempt = try await lifecycle.beginAuthorization()
                lifecycle.setBillingConfirmed(true)
                try await lifecycle.commit(fixtureCredentials("new-account-needs-confirmation"), attempt: attempt)
                try lifecycle.markReady(attempt, models: fixtureModels)
                try require(!lifecycle.billingConfirmed && !lifecycle.canRun, "New account inherited old billing confirmation")
                lifecycle.setBillingConfirmed(true)
                try require(lifecycle.canRun, "Fresh current-account confirmation cannot enable run")
                let owner = lifecycle.invalidate(); _ = await lifecycle.finishCleanup(owner: owner)
            }),
            ("cancel before token prevents late commit and permits explicit retry", {
                let (lifecycle, store) = fixture()
                let attempt = try await lifecycle.beginAuthorization()
                let owner = lifecycle.invalidate()
                let result = await lifecycle.finishCleanup(owner: owner)
                var cancelled = false
                do { try await lifecycle.commit(fixtureCredentials("late"), attempt: attempt) } catch is CancellationError { cancelled = true }
                try require(cancelled && lifecycle.canAuthorize && !lifecycle.authenticated, "Cancelled authorization reactivated")
                try require(await store.snapshot() == nil && result.local == .removed, "Memory not cleared")
            }),
            ("cancel after save before catalog clears memory, models and billing", {
                let (lifecycle, store) = fixture()
                let attempt = try await lifecycle.beginAuthorization()
                try await lifecycle.commit(fixtureCredentials("saved-before-catalog"), attempt: attempt)
                let owner = lifecycle.invalidate(); _ = await lifecycle.finishCleanup(owner: owner)
                try require(await store.snapshot() == nil, "Saved credentials survived cancellation")
                try require(lifecycle.canAuthorize && lifecycle.models.isEmpty && !lifecycle.billingConfirmed, "Cancelled state cannot retry cleanly")
            }),
            ("catalog failure follows cleanup and re-enables a fresh authorization", {
                let (lifecycle, store) = fixture()
                let attempt = try await lifecycle.beginAuthorization()
                try await lifecycle.commit(fixtureCredentials("catalog-failed"), attempt: attempt)
                // The controller's catch invokes this same invalidate + cleanup sequence.
                let owner = lifecycle.invalidate(); let result = await lifecycle.finishCleanup(owner: owner)
                try require(await store.snapshot() == nil && lifecycle.canAuthorize, "Catalog failure retained account")
                try require(result.remote == .unconfirmed && !benchmarkCleanupMessage(result).contains("Remote revocation confirmed."), "Remote failure reported confirmed")
            }),
            ("insufficient candidates cannot mark authenticated and are cleaned", {
                let (lifecycle, store) = fixture()
                let attempt = try await lifecycle.beginAuthorization()
                try await lifecycle.commit(fixtureCredentials("too-few-models"), attempt: attempt)
                var failed = false
                do { try lifecycle.markReady(attempt, models: Array(fixtureModels.prefix(2))) } catch { failed = true }
                let owner = lifecycle.invalidate(); _ = await lifecycle.finishCleanup(owner: owner)
                try require(failed && lifecycle.canAuthorize && lifecycle.models.isEmpty && !lifecycle.billingConfirmed, "Insufficient catalog became ready")
                try require(await store.snapshot() == nil, "Insufficient catalog retained credentials")
            }),
            ("cancelled noncooperative old commit cannot overwrite a new account", {
                let (lifecycle, store) = fixture()
                let old = try await lifecycle.beginAuthorization()
                let owner = lifecycle.invalidate(); _ = await lifecycle.finishCleanup(owner: owner)
                _ = try await ready(lifecycle, token: "new-session")
                var rejected = false
                do { try await store.save(fixtureCredentials("late-old-session"), expectedEpoch: old.storeEpoch, authorization: old.permit) } catch is CancellationError { rejected = true }
                let active = await store.snapshot()
                try require(rejected && active?.accessToken == "new-session", "Old permit replaced new session")
            }),
            ("caller task cancellation cannot submit credentials", {
                let (lifecycle, store) = fixture()
                let attempt = try await lifecycle.beginAuthorization()
                let task = Task { @MainActor in
                    withUnsafeCurrentTask { $0?.cancel() }
                    try await lifecycle.commit(fixtureCredentials("cancelled-caller"), attempt: attempt)
                }
                var rejected = false
                do { try await task.value } catch is CancellationError { rejected = true }
                let owner = lifecycle.invalidate(); _ = await lifecycle.finishCleanup(owner: owner)
                let active = await store.snapshot()
                try require(rejected && active == nil, "Cancelled caller saved credentials")
            }),
            ("close while running prevents every subsequent dispatch and clears local session", {
                let (lifecycle, store) = fixture()
                _ = try await ready(lifecycle)
                let run = try lifecycle.beginRun()
                let owner = lifecycle.invalidate(closing: true)
                var dispatched = 0
                for _ in 0..<39 { do { try lifecycle.ensureCurrent(run); dispatched += 1 } catch {} }
                let result = await lifecycle.finishCleanup(owner: owner)
                try require(dispatched == 0 && lifecycle.phase == .closed && !lifecycle.canAuthorize && !lifecycle.billingConfirmed && lifecycle.models.isEmpty, "Closing allowed work or retry")
                try require(await store.snapshot() == nil && result.remote == .unconfirmed, "Close retained credentials or invented revocation")
            }),
            ("overlapping cancel and close share one remote cleanup", {
                let gate = RevocationGate()
                let store = ChatGPTSessionStore(storage: BenchmarkMemoryStorage(), revocationOperation: { _ in await gate.revoke() })
                let lifecycle = BenchmarkLifecycle(store: store)
                _ = try await ready(lifecycle)
                let cancelled = lifecycle.invalidate()
                let first = Task { await lifecycle.finishCleanup(owner: cancelled) }
                await gate.waitUntilStarted()
                let closed = lifecycle.invalidate(closing: true)
                let second = Task { await lifecycle.finishCleanup(owner: closed) }
                await Task.yield(); await gate.release()
                _ = await first.value; let result = await second.value
                try require(await gate.calls == 1 && lifecycle.phase == .closed, "Duplicate cleanup or close reopened app")
                try require(await store.snapshot() == nil && result.remote == .unconfirmed, "Close cleanup result dishonest")
            }),
            ("obsolete cleanup cannot remove a later session", {
                let (lifecycle, store) = fixture()
                let obsolete = lifecycle.invalidate(); _ = await lifecycle.finishCleanup(owner: obsolete)
                _ = try await ready(lifecycle, token: "later-account")
                let result = await lifecycle.finishCleanup(owner: obsolete)
                try require((await store.snapshot())?.accessToken == "later-account" && result.local == .notChecked, "Obsolete cleanup erased later account")
            }),
            ("write failure retains one original row and does not claim saved", {
                let ledger = BenchmarkRowLedger()
                var failed = false
                do { try ledger.append(row(1)) { _ in throw BenchmarkPersistenceFailure() } } catch is BenchmarkPersistenceFailure { failed = true }
                try require(failed && ledger.rows.count == 1 && ledger.rows[0].outcome == "success" && ledger.persistedCount == 0, "Write failure duplicated or changed network result")
                do { try ledger.append(row(1, outcome: "failure")) { _ in } } catch {}
                try require(ledger.rows.count == 1 && ledger.persistedCount == 0, "Repeated index appended another row")
            }),
            ("first request failure records one row then stops the real schedule", {
                let jobs = try BenchmarkSchedule.make(modelCount: 3, fixtureCount: 4)
                let ledger = BenchmarkRowLedger(); var dispatched = 0
                do {
                    for _ in jobs {
                        dispatched += 1
                        try ledger.append(row(dispatched, outcome: "failure")) { _ in }
                        throw URLError(.notConnectedToInternet)
                    }
                } catch {}
                try require(dispatched == 1 && ledger.rows.count == 1 && ledger.persistedCount == 1, "First error retried or lost persisted failure")
                try BenchmarkSchedule.checkInvariants()
            }),
            ("remote confirmation, no-refresh and unconfirmed statuses remain distinct", {
                let confirmed = SessionSignOutResult(local: .removed, remote: .confirmed)
                let noRefresh = SessionSignOutResult(local: .removed, remote: .notNeeded)
                let unknown = SessionSignOutResult(local: .removed, remote: .unconfirmed)
                try require(benchmarkCleanupMessage(confirmed).contains("Remote revocation confirmed."), "Confirmation lost")
                try require(!benchmarkCleanupMessage(noRefresh).contains("Remote revocation confirmed.") && !benchmarkCleanupMessage(unknown).contains("Remote revocation confirmed."), "Unconfirmed/no-refresh mislabeled")
            })
        ]
        for (name, scenario) in scenarios { try await scenario(); print("PASS: " + name) }
        print("PASS: \(scenarios.count) Mac benchmark lifecycle/recording scenarios. Synthetic memory-only credentials and injected revocation; no UI, login, network, other-app cache, Keychain or device access.")
    }
}
