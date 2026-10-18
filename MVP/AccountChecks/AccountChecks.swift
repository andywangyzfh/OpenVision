import Darwin
import Foundation
import SubscriptionCore

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
private func expect(_ value: Bool, _ message: String) throws { if !value { throw CheckFailure(message) } }
private func eventually(_ message: String, _ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<500 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw CheckFailure("Timed out: " + message)
}
private func drain() async {
    for _ in 0..<30 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(5))
}
private func failure(_ task: Task<String, Error>) async -> Error? {
    do { _ = try await task.value; return nil } catch { return error }
}

@main
struct AccountChecks {
    static func main() async {
        let scenarios: [(String, @Sendable () async throws -> Void)] = [
            ("restores only the injected record and reuses a fresh access token", {
                let initial = credential(fresh: true)
                let (store, storage, refresh, _) = fixture(initial)
                try expect(try await store.accessToken() == initial.accessToken, "Restored token changed")
                try expect(await refresh.count() == 0 && storage.saveCount() == 0, "Fresh token triggered refresh/persistence")
                try expect(await store.snapshot()?.subject == initial.subject, "Restored identity changed")
            }),
            ("concurrent expired callers share one refresh and durable rotating result", {
                let initial = credential(), next = updated(credential())
                let (store, storage, refresh, _) = fixture(initial)
                let first = Task { try await store.accessToken() }
                try await eventually("one refresh") { await refresh.count() == 1 }
                let rest = (0..<5).map { _ in Task { try await store.accessToken() } }
                await drain()
                try expect(await refresh.count() == 1, "Concurrent calls launched multiple refreshes")
                await refresh.resolve(0, .success(next))
                try expect(try await first.value == next.accessToken, "Owner did not receive new access token")
                for task in rest { try expect(try await task.value == next.accessToken, "Waiter received a different token") }
                try expect(storage.snapshot()?.refreshToken == next.refreshToken && storage.saveCount() == 1, "Rotated refresh was not persisted exactly once")
            }),
            ("persistence failure fails every waiter and never releases an unpersisted token", {
                let initial = credential()
                let (store, storage, refresh, _) = fixture(initial)
                storage.failWrites(true)
                let first = Task { try await store.accessToken() }
                try await eventually("refresh") { await refresh.count() == 1 }
                let second = Task { try await store.accessToken() }
                let third = Task { try await store.accessToken() }
                await drain(); await refresh.resolve(0, .success(updated(initial)))
                for task in [first, second, third] {
                    try expect(await failure(task) as? PlanError == .service("fixture_write_failed"), "A waiter escaped the failed durable commit")
                }
                let current = await store.snapshot()
                try expect(storage.snapshot()?.accessToken == initial.accessToken && current?.accessToken == initial.accessToken, "Failed commit replaced credentials")
                storage.failWrites(false)
                let retry = Task { try await store.accessToken() }
                try await eventually("explicit retry") { await refresh.count() == 2 }
                let next = updated(initial, suffix: "retry")
                await refresh.resolve(1, .success(next))
                try expect(try await retry.value == next.accessToken, "Failed refresh task was not released for manual retry")
            }),
            ("invalid_grant clears memory and durable credentials for all waiters", {
                let (store, storage, refresh, _) = fixture(credential())
                let first = Task { try await store.accessToken() }
                try await eventually("refresh") { await refresh.count() == 1 }
                let second = Task { try await store.accessToken() }
                await drain(); await refresh.resolve(0, .failure(PlanError.reauthenticationRequired))
                try expect(await failure(first) as? PlanError == .reauthenticationRequired, "Owner did not require reauthentication")
                try expect(await failure(second) as? PlanError == .reauthenticationRequired, "Waiter did not require reauthentication")
                try expect(await store.snapshot() == nil && storage.snapshot() == nil, "Revoked credentials survived")
            }),
            ("sign-out cannot be undone by a late noncooperative refresh", {
                let initial = credential()
                let (store, storage, refresh, revoke) = fixture(initial)
                let request = Task { try await store.accessToken() }
                try await eventually("refresh") { await refresh.count() == 1 }
                try expect(await store.signOut(), "Fixture sign-out was not confirmed")
                await refresh.resolve(0, .success(updated(initial)))
                try expect(await failure(request) is CancellationError, "Late refresh was not discarded")
                try expect(await store.snapshot() == nil && storage.snapshot() == nil, "Late refresh resurrected signed-out credentials")
                try expect(await revoke.count() == 1, "Sign-out did not use injected revocation")
            }),
            ("new sign-in owns its refresh even when the old refresh completes later", {
                let initial = credential(), replacement = credential("new-account")
                let (store, storage, refresh, _) = fixture(initial)
                let oldRequest = Task { try await store.accessToken() }
                try await eventually("old refresh") { await refresh.count() == 1 }
                try await store.save(replacement)
                let newRequest = Task { try await store.accessToken() }
                try await eventually("new refresh") { await refresh.count() == 2 }
                await refresh.resolve(0, .success(updated(initial)))
                try expect(await failure(oldRequest) is CancellationError, "Old refresh was accepted after new sign-in")
                try expect(await store.snapshot()?.subject == replacement.subject, "Old refresh overwrote new identity")
                let waiter = Task { try await store.accessToken() }; await drain()
                try expect(await refresh.count() == 2, "Old defer cleared new refresh ownership")
                let next = updated(replacement)
                await refresh.resolve(1, .success(next))
                try expect(try await newRequest.value == next.accessToken, "New refresh owner failed")
                try expect(try await waiter.value == next.accessToken, "New refresh waiter failed")
                try expect(storage.snapshot()?.subject == replacement.subject, "Persistence lost new account")
            }),
            ("one cancelled caller cannot cancel the shared refresh for another", {
                let initial = credential(), next = updated(credential())
                let (store, storage, refresh, _) = fixture(initial)
                let cancelled = Task { try await store.accessToken() }
                try await eventually("refresh") { await refresh.count() == 1 }
                let surviving = Task { try await store.accessToken() }; await drain()
                cancelled.cancel(); await refresh.resolve(0, .success(next))
                try expect(await failure(cancelled) is CancellationError, "Cancelled caller received a token")
                try expect(try await surviving.value == next.accessToken && storage.snapshot()?.accessToken == next.accessToken, "Cancelled caller poisoned shared refresh")
                try expect(await refresh.count() == 1, "Cancellation triggered another refresh")
            }),
            ("stale HTTP 401 invalidates only the exact current request token", {
                let initial = credential(fresh: true), replacement = credential("new-account", fresh: true)
                let (store, storage, refresh, _) = fixture(initial)
                try await store.save(replacement)
                await store.discardIfMatching(initial.accessToken)
                try expect(try await store.accessToken() == replacement.accessToken, "Old HTTP error erased new account")
                await store.discardIfMatching(replacement.accessToken)
                try expect(await store.snapshot() == nil && storage.snapshot() == nil, "Matching invalidation did not clear credentials")
                try expect(await refresh.count() == 0, "Invalidation caused network refresh")
            }),
            ("expired credentials without refresh token require reauthentication", {
                let (store, storage, refresh, _) = fixture(credential(refresh: nil))
                let request = Task { try await store.accessToken() }
                try expect(await failure(request) as? PlanError == .reauthenticationRequired, "Missing refresh token did not require sign-in")
                let count = await refresh.count()
                try expect(await store.snapshot() == nil && storage.snapshot() == nil && count == 0, "Missing refresh token was not cleared locally")
            }),
            ("transient refresh failure retains credentials and does not retry implicitly", {
                let initial = credential()
                let (store, storage, refresh, _) = fixture(initial)
                let request = Task { try await store.accessToken() }
                try await eventually("refresh") { await refresh.count() == 1 }
                await refresh.resolve(0, .failure(URLError(.notConnectedToInternet)))
                try expect((await failure(request) as? URLError)?.code == .notConnectedToInternet, "Transient error was masked")
                try expect(await refresh.count() == 1 && storage.snapshot()?.accessToken == initial.accessToken, "Transient failure retried or deleted credentials")
            }),
            ("failed new-login persistence preserves the existing refresh ownership", {
                let initial = credential()
                let (store, storage, refresh, _) = fixture(initial)
                let request = Task { try await store.accessToken() }
                try await eventually("refresh") { await refresh.count() == 1 }
                storage.failWrites(true)
                do { try await store.save(credential("new-account")); throw CheckFailure("Expected save failure") }
                catch let error as PlanError { try expect(error == .service("fixture_write_failed"), "Unexpected save failure") }
                storage.failWrites(false)
                let next = updated(initial); await refresh.resolve(0, .success(next))
                try expect(try await request.value == next.accessToken && storage.snapshot()?.subject == initial.subject, "Failed login displaced existing session")
            }),
            ("unconfirmed remote revocation still removes local credentials", {
                let (store, storage, _, revoke) = fixture(credential(fresh: true), confirmedRevocation: false)
                try expect(!(await store.signOut()), "Remote revocation failure was hidden")
                let revocations = await revoke.count()
                try expect(await store.snapshot() == nil && storage.snapshot() == nil && revocations == 1, "Failed remote revoke retained local credentials")
            }),
            ("storage read failure cannot manufacture a signed-in session", {
                let storage = MemoryPlanStorage(credential(fresh: true)); storage.failReads(true)
                let refresh = RefreshFixture()
                let store = ChatGPTSessionStore(storage: storage, refreshOperation: { try await refresh.refresh($0) }, revocationOperation: { _ in true })
                let request = Task { try await store.accessToken() }
                let error = await failure(request), count = await refresh.count()
                try expect(error as? PlanError == .reauthenticationRequired && count == 0, "Unreadable storage initiated requests")
            })
        ]
        do {
            for (name, scenario) in scenarios { try await scenario(); print("PASS: " + name) }
            print("PASS: \(scenarios.count) production ChatGPTSessionStore actor scenarios using memory persistence and controlled refresh/revocation. No real network, Keychain or user tokens; actual iOS Keychain smoke is a separate XCTest gate.")
        } catch {
            FileHandle.standardError.write(Data("FAIL: account actor integration: \(error)\n".utf8)); exit(1)
        }
    }
}
