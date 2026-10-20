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
            ("cold init never loads even an allowed saved record; only explicit Resume does", {
                let saved = credential(fresh: true), secrets = MemoryPlanStorage(credential(fresh: true)), marker = MemoryRestorationMarker()
                let storage = ProtectedPlanCredentialStorage(secrets: secrets, marker: marker)
                let store = ChatGPTSessionStore(storage: storage, refreshOperation: { _ in saved }, revocationOperation: { _ in true })
                let cold = await store.uiState()
                try expect(cold.credentials == nil && cold.cleanup == .notChecked && secrets.loadCount() == 0, "Launch silently loaded an allowed record")
                let restored = try await resume(store)
                try expect(restored.credentials?.accessToken == saved.accessToken && secrets.loadCount() == 1, "Explicit user Resume did not load exactly once")
                try expect(restored.epoch > cold.epoch && restored.cleanup == .removed, "Resume did not advance the activation epoch")
            }),
            ("explicit Resume rejects blocked, missing and corrupt restoration markers", {
                for state in [String?.none, "blocked\n", "corrupt-state"] {
                    let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenVision-resume-" + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: root) }
                    let marker = FilePlanRestorationMarker(service: "fixture", key: "session", root: root)
                    if let state {
                        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        try Data(state.utf8).write(to: marker.fileURL)
                    }
                    let saved = credential(fresh: true), secrets = MemoryPlanStorage(credential(fresh: true))
                    let store = ChatGPTSessionStore(storage: ProtectedPlanCredentialStorage(secrets: secrets, marker: marker), refreshOperation: { _ in saved }, revocationOperation: { _ in true })
                    let result = try await resume(store)
                    try expect(result.credentials == nil && secrets.loadCount() == 0, "A non-allowed marker restored credentials")
                }
            }),
            ("stale queued Resume cannot read a record after cleanup, including double durable failure", {
                let saved = credential(fresh: true), secrets = MemoryPlanStorage(credential(fresh: true)), marker = MemoryRestorationMarker()
                let store = ChatGPTSessionStore(storage: ProtectedPlanCredentialStorage(secrets: secrets, marker: marker), refreshOperation: { _ in saved }, revocationOperation: { _ in true })
                let epoch = await store.authorizationEpoch(), permit = PlanAuthorizationPermit()
                secrets.failDeletes(true); marker.failBlock(true)
                _ = await store.signOut()
                do { _ = try await store.resumeSavedCredentials(expectedEpoch: epoch, authorization: permit); throw CheckFailure("Stale Resume was accepted") }
                catch is CancellationError {}
                try expect(await store.snapshot() == nil && secrets.loadCount() == 0, "Queued Resume read an unsafe leftover after sign-out")
            }),
            ("new OAuth commit rejects an older queued Resume without reading old storage", {
                let saved = credential(fresh: true), secrets = MemoryPlanStorage(credential(fresh: true))
                let store = ChatGPTSessionStore(storage: secrets, refreshOperation: { _ in saved }, revocationOperation: { _ in true })
                let epoch = await store.authorizationEpoch(), restorePermit = PlanAuthorizationPermit()
                let replacement = credential("new-oauth", fresh: true)
                try await store.save(replacement, expectedEpoch: epoch, authorization: PlanAuthorizationPermit())
                do { _ = try await store.resumeSavedCredentials(expectedEpoch: epoch, authorization: restorePermit); throw CheckFailure("Old Resume replaced OAuth identity") }
                catch is CancellationError {}
                try expect(await store.snapshot()?.subject == replacement.subject && secrets.loadCount() == 0, "Resume overwrote the new account")
            }),
            ("explicit Resume invalidates an older queued OAuth authorization", {
                let saved = credential(fresh: true), secrets = MemoryPlanStorage(credential(fresh: true))
                let store = ChatGPTSessionStore(storage: secrets, refreshOperation: { _ in saved }, revocationOperation: { _ in true })
                let epoch = await store.authorizationEpoch(), authPermit = PlanAuthorizationPermit()
                _ = try await resume(store)
                let oldSave = Task {
                    try await store.save(credential("stale-oauth", fresh: true), expectedEpoch: epoch, authorization: authPermit)
                    return "unexpected commit"
                }
                try expect(await failure(oldSave) is CancellationError, "Old OAuth replaced a newer explicit restoration")
                try expect(await store.snapshot()?.subject == saved.subject && secrets.saveCount() == 0, "Stale OAuth wrote credentials")
            }),
            ("cancelled Resume permit reads no credentials and changes no epoch", {
                let saved = credential(fresh: true), secrets = MemoryPlanStorage(credential(fresh: true))
                let store = ChatGPTSessionStore(storage: secrets, refreshOperation: { _ in saved }, revocationOperation: { _ in true })
                let epoch = await store.authorizationEpoch(), permit = PlanAuthorizationPermit(); permit.cancel()
                do { _ = try await store.resumeSavedCredentials(expectedEpoch: epoch, authorization: permit); throw CheckFailure("Cancelled Resume was accepted") }
                catch is CancellationError {}
                let state = await store.uiState()
                try expect(state.credentials == nil && state.epoch == epoch && secrets.loadCount() == 0, "Cancelled Resume touched persisted credentials")
            }),
            ("cancelled caller Task cannot perform its queued explicit Resume read", {
                let saved = credential(fresh: true), secrets = MemoryPlanStorage(credential(fresh: true)), startGate = RefreshFixture()
                let store = ChatGPTSessionStore(storage: secrets, refreshOperation: { _ in saved }, revocationOperation: { _ in true })
                let epoch = await store.authorizationEpoch(), permit = PlanAuthorizationPermit()
                let request = Task {
                    _ = try await startGate.refresh(saved) // controlled gate intentionally ignores cancellation
                    _ = try await store.resumeSavedCredentials(expectedEpoch: epoch, authorization: permit)
                    return "unexpected resume"
                }
                try await eventually("resume call held before actor entry") { await startGate.count() == 1 }
                request.cancel(); await startGate.resolve(0, .success(saved))
                try expect(await failure(request) is CancellationError && secrets.loadCount() == 0, "Cancelled caller loaded saved credentials")
            }),
            ("late activation cleanup cannot delete a same-token newer session", {
                let saved = credential(fresh: true), secrets = MemoryPlanStorage(credential(fresh: true))
                let store = ChatGPTSessionStore(storage: secrets, refreshOperation: { _ in saved }, revocationOperation: { _ in true })
                let restored = try await resume(store)
                try await store.save(saved, expectedEpoch: restored.epoch, authorization: PlanAuthorizationPermit())
                await store.discardIfMatching(saved.accessToken, expectedEpoch: restored.epoch)
                try expect(await store.snapshot()?.accessToken == saved.accessToken && secrets.snapshot() != nil, "Old activation cleanup erased a newer same-token session")
            }),
            ("restores only the injected record and reuses a fresh access token", {
                let initial = credential(fresh: true)
                let (store, storage, refresh, _) = try await fixture(initial)
                try expect(try await store.accessToken() == initial.accessToken, "Restored token changed")
                try expect(await refresh.count() == 0 && storage.saveCount() == 0, "Fresh token triggered refresh/persistence")
                try expect(await store.snapshot()?.subject == initial.subject, "Restored identity changed")
            }),
            ("concurrent expired callers share one refresh and durable rotating result", {
                let initial = credential(), next = updated(credential())
                let (store, storage, refresh, _) = try await fixture(initial)
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
                let (store, storage, refresh, _) = try await fixture(initial)
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
                let (store, storage, refresh, _) = try await fixture(credential())
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
                let (store, storage, refresh, revoke) = try await fixture(initial)
                let request = Task { try await store.accessToken() }
                try await eventually("refresh") { await refresh.count() == 1 }
                try expect(await store.signOut().complete, "Fixture sign-out was not confirmed")
                await refresh.resolve(0, .success(updated(initial)))
                try expect(await failure(request) is CancellationError, "Late refresh was not discarded")
                try expect(await store.snapshot() == nil && storage.snapshot() == nil, "Late refresh resurrected signed-out credentials")
                try expect(await revoke.count() == 1, "Sign-out did not use injected revocation")
            }),
            ("new sign-in owns its refresh even when the old refresh completes later", {
                let initial = credential(), replacement = credential("new-account")
                let (store, storage, refresh, _) = try await fixture(initial)
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
                let (store, storage, refresh, _) = try await fixture(initial)
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
                let (store, storage, refresh, _) = try await fixture(initial)
                try await store.save(replacement)
                await store.discardIfMatching(initial.accessToken)
                try expect(try await store.accessToken() == replacement.accessToken, "Old HTTP error erased new account")
                await store.discardIfMatching(replacement.accessToken)
                try expect(await store.snapshot() == nil && storage.snapshot() == nil, "Matching invalidation did not clear credentials")
                try expect(await refresh.count() == 0, "Invalidation caused network refresh")
            }),
            ("expired credentials without refresh token require reauthentication", {
                let (store, storage, refresh, _) = try await fixture(credential(refresh: nil))
                let request = Task { try await store.accessToken() }
                try expect(await failure(request) as? PlanError == .reauthenticationRequired, "Missing refresh token did not require sign-in")
                let count = await refresh.count()
                try expect(await store.snapshot() == nil && storage.snapshot() == nil && count == 0, "Missing refresh token was not cleared locally")
            }),
            ("transient refresh failure retains credentials and does not retry implicitly", {
                let initial = credential()
                let (store, storage, refresh, _) = try await fixture(initial)
                let request = Task { try await store.accessToken() }
                try await eventually("refresh") { await refresh.count() == 1 }
                await refresh.resolve(0, .failure(URLError(.notConnectedToInternet)))
                try expect((await failure(request) as? URLError)?.code == .notConnectedToInternet, "Transient error was masked")
                try expect(await refresh.count() == 1 && storage.snapshot()?.accessToken == initial.accessToken, "Transient failure retried or deleted credentials")
            }),
            ("failed new-login persistence preserves the existing refresh ownership", {
                let initial = credential()
                let (store, storage, refresh, _) = try await fixture(initial)
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
                let (store, storage, _, revoke) = try await fixture(credential(fresh: true), confirmedRevocation: false)
                try expect(!(await store.signOut().complete), "Remote revocation failure was hidden")
                let revocations = await revoke.count()
                try expect(await store.snapshot() == nil && storage.snapshot() == nil && revocations == 1, "Failed remote revoke retained local credentials")
            }),
            ("storage read failure cannot manufacture or claim a cleared session", {
                let storage = MemoryPlanStorage(credential(fresh: true)); storage.failReads(true)
                let refresh = RefreshFixture()
                let store = ChatGPTSessionStore(storage: storage, refreshOperation: { try await refresh.refresh($0) }, revocationOperation: { _ in true })
                _ = try await resume(store)
                let request = Task { try await store.accessToken() }
                let error = await failure(request), count = await refresh.count()
                try expect(error as? PlanError == .reauthenticationRequired && count == 0, "Unreadable storage initiated requests")
                try expect(await store.cleanupState() == .unsafeFailure(nil), "Unreadable storage was presented as confirmed cleanup")
            }),
            ("failed deletion is reported while durable marker prevents cold-start restoration", {
                let (store, secrets, marker, _, storage) = try await protectedFixture(credential(fresh: true))
                secrets.failDeletes(true)
                let result = await store.signOut()
                try expect(result.local == .blockedPendingDeletion(-25308) && !result.complete, "Failed delete was reported as successful sign-out")
                try expect(secrets.snapshot() != nil && (try marker.isBlocked()), "Marker did not precede failed deletion")
                let cold = ChatGPTSessionStore(storage: storage, refreshOperation: { _ in throw PlanError.service("must_not_refresh") }, revocationOperation: { _ in true })
                try expect(await cold.snapshot() == nil, "Failed-deletion credentials were restored after restart")
                _ = try await resume(cold)
                try expect(await cold.cleanupState() == .blockedPendingDeletion(-25308), "Cold start hid pending cleanup")
            }),
            ("marker and deletion double failure is explicitly unsafe, not a safe-exit pass", {
                let (store, secrets, marker, _, storage) = try await protectedFixture(credential(fresh: true))
                secrets.failDeletes(true); marker.failBlock(true)
                let result = await store.signOut()
                try expect(result.local == .unsafeFailure(-25308) && !result.complete, "Double failure was claimed safe")
                try expect(!(try marker.isBlocked()) && secrets.snapshot() != nil, "Fixture did not exercise double durable failure")
                // Durable cleanup is still unsafe, but cold init must not silently activate it.
                let cold = ChatGPTSessionStore(storage: storage, refreshOperation: { _ in throw PlanError.service("must_not_refresh") }, revocationOperation: { _ in true })
                try expect(await cold.snapshot() == nil, "Double failure silently restored a cold session")
                try expect(await cold.cleanupState() == .notChecked, "Cold state claimed credentials were checked or removed")
                try expect(secrets.loadCount() == 1, "Double failure triggered an automatic cold read")
            }),
            ("deletion success remains safe even if marker writing fails", {
                let (store, secrets, marker, _, storage) = try await protectedFixture(credential(fresh: true))
                marker.failBlock(true)
                let result = await store.signOut()
                try expect(result.complete && secrets.snapshot() == nil, "Successful secret deletion was not confirmed")
                let cold = ChatGPTSessionStore(storage: storage, refreshOperation: { _ in throw PlanError.service("must_not_refresh") }, revocationOperation: { _ in true })
                _ = try await resume(cold)
                try expect(await cold.snapshot() == nil, "Deleted credentials restored")
            }),
            ("explicit retry clears blocked leftovers and preserves remote failure notice", {
                let initial = credential(fresh: true), secrets = MemoryPlanStorage(credential(fresh: true)), marker = MemoryRestorationMarker()
                let storage = ProtectedPlanCredentialStorage(secrets: secrets, marker: marker)
                let store = ChatGPTSessionStore(storage: storage, refreshOperation: { _ in initial }, revocationOperation: { _ in false })
                _ = try await resume(store)
                secrets.failDeletes(true)
                let first = await store.signOut()
                try expect(first.local == .blockedPendingDeletion(-25308) && !first.remoteRevoked, "Initial failure classification wrong")
                secrets.failDeletes(false)
                let retried = await store.retryLocalCleanup()
                try expect(retried.local == .removed && !retried.remoteRevoked && !retried.complete, "Local retry pretended remote revoke succeeded")
                try expect(secrets.snapshot() == nil && (try marker.isBlocked()), "Retry left credentials recoverable")
            }),
            ("new login replaces blocked record and old cleanup retry cannot delete it", {
                let (store, secrets, marker, _, _) = try await protectedFixture(credential(fresh: true))
                secrets.failDeletes(true); _ = await store.signOut()
                let replacement = credential("new-account", fresh: true)
                try await store.save(replacement)
                try expect(!(try marker.isBlocked()) && secrets.snapshot()?.subject == replacement.subject, "New login did not commit its own restoration grant")
                let deletes = secrets.clearCount()
                let retried = await store.retryLocalCleanup()
                try expect(retried.complete && secrets.clearCount() == deletes, "Old cleanup retry deleted a new login")
                try expect(try await store.accessToken() == replacement.accessToken, "New login was lost")
            }),
            ("late pre-signout refresh cannot unblock a failed deletion", {
                let initial = credential()
                let (store, secrets, marker, refresh, storage) = try await protectedFixture(initial)
                let request = Task { try await store.accessToken() }
                try await eventually("refresh pending") { await refresh.count() == 1 }
                secrets.failDeletes(true); _ = await store.signOut()
                await refresh.resolve(0, .success(updated(initial)))
                try expect(await failure(request) is CancellationError, "Cancelled refresh returned a token")
                try expect(try marker.isBlocked(), "Late refresh removed signed-out marker")
                let cold = ChatGPTSessionStore(storage: storage, refreshOperation: { _ in throw PlanError.service("must_not_refresh") }, revocationOperation: { _ in true })
                _ = try await resume(cold)
                try expect(await cold.snapshot() == nil, "Late refresh re-enabled cold restoration")
            }),
            ("failed allow commit never restores the old blocked record", {
                let (store, secrets, marker, _, storage) = try await protectedFixture(credential(fresh: true))
                secrets.failDeletes(true); _ = await store.signOut(); marker.failAllow(true)
                do { try await store.save(credential("new-account", fresh: true)); throw CheckFailure("Expected allow write failure") }
                catch is CredentialCleanupError {}
                try expect(try marker.isBlocked(), "Failed allow removed protection")
                let cold = ChatGPTSessionStore(storage: storage, refreshOperation: { _ in throw PlanError.service("must_not_refresh") }, revocationOperation: { _ in true })
                _ = try await resume(cold)
                try expect(await cold.snapshot() == nil, "Failed authorization commit restored credentials")
            }),
            ("marker read failure refuses restoration and does not claim deletion", {
                let secrets = MemoryPlanStorage(credential(fresh: true)), marker = MemoryRestorationMarker()
                marker.failRead(true)
                let store = ChatGPTSessionStore(storage: ProtectedPlanCredentialStorage(secrets: secrets, marker: marker), refreshOperation: { _ in throw PlanError.service("must_not_refresh") }, revocationOperation: { _ in true })
                _ = try await resume(store)
                try expect(await store.snapshot() == nil, "Unreadable restoration state was trusted")
                try expect(await store.cleanupState() == .unsafeFailure(nil) && secrets.snapshot() != nil, "Marker error was hidden as confirmed deletion")
            }),
            ("real marker file is non-secret, survives reconstruction and isolates namespaces", {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenVision-marker-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let first = FilePlanRestorationMarker(service: "fixture-A", key: "session", root: root)
                let second = FilePlanRestorationMarker(service: "fixture-B", key: "session", root: root)
                try expect(try first.isBlocked(), "Missing marker allowed stale Keychain restoration")
                try first.allow(); try second.allow(); try first.block()
                let reconstructed = FilePlanRestorationMarker(service: "fixture-A", key: "session", root: root)
                try expect(try reconstructed.isBlocked(), "Blocked marker did not persist")
                try expect(!(try second.isBlocked()) && first.fileURL != second.fileURL, "One namespace blocked another")
                try expect(try Data(contentsOf: first.fileURL) == Data("blocked\n".utf8), "Marker contains unexpected secret material")
            }),
            ("cleanup is idempotent and does not touch another secret namespace", {
                let (store, secrets, _, _, _) = try await protectedFixture(credential(fresh: true))
                let (other, otherSecrets, _, _, _) = try await protectedFixture(credential("other", fresh: true))
                let first = await store.signOut(), second = await store.retryLocalCleanup()
                try expect(first.complete && second.complete && secrets.snapshot() == nil, "Repeated cleanup was not idempotent")
                try expect(try await other.accessToken() == "synthetic-access-other" && otherSecrets.clearCount() == 0, "Cleanup crossed namespaces")
            }),
            ("remote revoke failure remains unconfirmed after cold cleanup and retry", {
                let initial = credential(fresh: true), secrets = MemoryPlanStorage(credential(fresh: true)), marker = MemoryRestorationMarker()
                let storage = ProtectedPlanCredentialStorage(secrets: secrets, marker: marker)
                let store = ChatGPTSessionStore(storage: storage, refreshOperation: { _ in initial }, revocationOperation: { _ in false })
                _ = try await resume(store)
                secrets.failDeletes(true)
                let result = await store.signOut()
                try expect(result.remote == .unconfirmed, "Failed revoke was confirmed")
                secrets.failDeletes(false)
                let cold = ChatGPTSessionStore(storage: storage, refreshOperation: { _ in initial }, revocationOperation: { _ in true })
                _ = try await resume(cold)
                let retried = await cold.retryLocalCleanup()
                try expect(retried.local == .removed && retried.remote == .unconfirmed && !retried.complete, "Cold restart manufactured remote confirmation")
            }),
            ("no renewable token is notNeeded, never an endpoint-confirmed revoke", {
                let (store, _, _, revoke) = try await fixture(credential(fresh: true, refresh: nil))
                let result = await store.signOut()
                try expect(result.local == .removed && result.remote == .notNeeded && !result.remoteRevoked, "No-token sign-out claimed endpoint confirmation")
                try expect(await revoke.count() == 0, "No-token sign-out attempted remote revoke")
            }),
            ("failed new-session commit cannot inherit the old session's remote confirmation", {
                let (store, secrets, marker, _, _) = try await protectedFixture(credential(fresh: true))
                secrets.failDeletes(true)
                let oldSignOut = await store.signOut()
                try expect(oldSignOut.remote == .confirmed && oldSignOut.local == .blockedPendingDeletion(-25308), "Fixture did not begin with confirmed old revoke and retained local record")
                marker.failAllow(true)
                let newSession = credential("new-remote-session", fresh: true)
                let epoch = await store.authorizationEpoch(), permit = PlanAuthorizationPermit()
                do { try await store.save(newSession, expectedEpoch: epoch, authorization: permit); throw CheckFailure("Expected restoration grant failure") }
                catch is CredentialCleanupError {}
                try expect(secrets.snapshot()?.subject == newSession.subject, "Fixture did not retain a partially committed new session")
                secrets.failDeletes(false); marker.failAllow(false)
                let cleanup = await store.retryLocalCleanup()
                try expect(cleanup.local == .removed && cleanup.remote == .unconfirmed && !cleanup.complete, "Failed new session inherited a previous session's confirmed revoke")
            }),
            ("empty cold session cannot claim a prior remote revocation", {
                let (store, _, _, _) = try await fixture(nil)
                let result = await store.signOut()
                try expect(result.remote == .unconfirmed && !result.remoteRevoked, "Empty session fabricated a confirmed revoke")
            }),
            ("cancelled authorization permit refuses queued save behind durable refresh", {
                let initial = credential(), secrets = MemoryPlanStorage(credential()), blocking = BlockingSaveStorage(secrets)
                let marker = MemoryRestorationMarker(), refresh = RefreshFixture()
                let protected = ProtectedPlanCredentialStorage(secrets: blocking, marker: marker)
                let store = ChatGPTSessionStore(storage: protected, refreshOperation: { try await refresh.refresh($0) }, revocationOperation: { _ in true })
                _ = try await resume(store)
                let epoch = await store.authorizationEpoch(), permit = PlanAuthorizationPermit()
                blocking.arm()
                let request = Task { try await store.accessToken() }
                try await eventually("refresh pending") { await refresh.count() == 1 }
                let refreshed = updated(initial)
                await refresh.resolve(0, .success(refreshed))
                try await eventually("durable refresh commit holds actor") { blocking.isHolding() }
                let oldSave = Task {
                    try await store.save(credential("cancelled-login", fresh: true), expectedEpoch: epoch, authorization: permit)
                    return "unexpected commit"
                }
                await drain(); permit.cancel(); blocking.resume()
                try expect(try await request.value == refreshed.accessToken, "Authorized refresh was broken by unrelated cancellation")
                try expect(await failure(oldSave) is CancellationError, "Cancelled queued save committed credentials")
                try expect(secrets.snapshot()?.subject == initial.subject, "Cancelled save overwrote durable identity")
                let cold = ChatGPTSessionStore(storage: protected, refreshOperation: { _ in initial }, revocationOperation: { _ in true })
                try expect(await cold.snapshot() == nil, "Cold init restored an account without user action")
                let restored = try await resume(cold)
                try expect(restored.credentials?.subject == initial.subject, "Explicit resume restored the cancelled login")
            }),
            ("caller Task cancellation while queued never writes credentials or an allow grant", {
                let initial = credential(), secrets = MemoryPlanStorage(credential()), blocking = BlockingSaveStorage(secrets)
                let marker = MemoryRestorationMarker(), refresh = RefreshFixture()
                let protected = ProtectedPlanCredentialStorage(secrets: blocking, marker: marker)
                let store = ChatGPTSessionStore(storage: protected, refreshOperation: { try await refresh.refresh($0) }, revocationOperation: { _ in true })
                _ = try await resume(store)
                let epoch = await store.authorizationEpoch(), permit = PlanAuthorizationPermit()
                blocking.arm()
                let request = Task { try await store.accessToken() }
                try await eventually("refresh pending") { await refresh.count() == 1 }
                let refreshed = updated(initial); await refresh.resolve(0, .success(refreshed))
                try await eventually("durable refresh holds actor") { blocking.isHolding() }
                let queued = Task {
                    try await store.save(credential("task-cancelled-login", fresh: true), expectedEpoch: epoch, authorization: permit)
                    return "unexpected commit"
                }
                await drain(); queued.cancel(); blocking.resume()
                _ = try await request.value
                try expect(await failure(queued) is CancellationError, "Caller cancellation was only noticed after durable save")
                try expect(secrets.saveCount() == 1 && secrets.snapshot()?.subject == initial.subject, "Cancelled caller wrote credentials/allow state")
            }),
            ("sign-out epoch rejects an older authorization even with a valid permit", {
                let (store, secrets, marker, _, protected) = try await protectedFixture(credential(fresh: true))
                let epoch = await store.authorizationEpoch(), permit = PlanAuthorizationPermit()
                _ = await store.signOut()
                let save = Task {
                    try await store.save(credential("late-login", fresh: true), expectedEpoch: epoch, authorization: permit)
                    return "unexpected commit"
                }
                try expect(await failure(save) is CancellationError, "Older authorization survived sign-out generation")
                try expect(secrets.snapshot() == nil && (try marker.isBlocked()), "Old authorization restored a credential or allow marker")
                let cold = ChatGPTSessionStore(storage: protected, refreshOperation: { _ in throw PlanError.service("must_not_refresh") }, revocationOperation: { _ in true })
                _ = try await resume(cold)
                try expect(await cold.snapshot() == nil, "Old authorization restored after cold start")
            }),
            ("authorization permit is one-shot and a consumed permit cannot replace a new login", {
                let (store, secrets, _, _, _) = try await protectedFixture(credential(fresh: true))
                let epoch = await store.authorizationEpoch(), permit = PlanAuthorizationPermit()
                let first = credential("authorized-login", fresh: true)
                try await store.save(first, expectedEpoch: epoch, authorization: permit)
                let nextEpoch = await store.authorizationEpoch()
                let repeated = Task {
                    try await store.save(credential("reused-permit", fresh: true), expectedEpoch: nextEpoch, authorization: permit)
                    return "unexpected commit"
                }
                try expect(await failure(repeated) is CancellationError && secrets.snapshot()?.subject == first.subject, "Consumed permit was reused")
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
