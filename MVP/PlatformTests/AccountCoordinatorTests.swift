import Foundation
import SubscriptionCore
import XCTest

/// Executes the actual ChatGPTAccountService coordinator and actual Store. Browser/listener,
/// token HTTP and identity/JWKS HTTP effects are injected; this is NOT an end-to-end test of
/// ASWebAuthenticationSession, real callback compatibility or a real ChatGPT account.
final class AccountCoordinatorTests: XCTestCase {
    @MainActor
    func testColdStartupNeverReadsOrActivatesAllowedBlockedOrCorruptStoredCredentials() async throws {
        let failures: [Error?] = [nil, CredentialCleanupError.deletionFailed(restorationBlocked: true, status: -25308), CredentialCleanupError.restorationStateUnavailable, PlanError.service("synthetic_corrupt")]
        for failure in failures {
            let storage = CoordinatorCredentialStorage(initial: coordinatorCredentials("saved"))
            storage.setLoadError(failure)
            let fixture = CoordinatorFixture(storage: storage)
            let service = fixture.service()
            await coordinatorDrain()
            XCTAssertFalse(service.isSignedIn)
            XCTAssertFalse(service.isSigningIn)
            XCTAssertEqual(service.localCleanupState, .notChecked)
            XCTAssertFalse(service.needsLocalCleanupRetry)
            XCTAssertEqual(storage.loads, 0)
            XCTAssertEqual(fixture.metadata.reads, 0)
            XCTAssertEqual(fixture.storeLookups.value, 0)
            let tokenCalls = await fixture.effects.tokenCount
            XCTAssertEqual(tokenCalls, 0)
        }
    }

    @MainActor
    func testExplicitResumeAloneRestoresSavedCredentialsWithoutOAuthOrMetadataReads() async throws {
        let saved = coordinatorCredentials("saved")
        let storage = CoordinatorCredentialStorage(initial: saved)
        let fixture = CoordinatorFixture(storage: storage)
        let service = fixture.service()
        XCTAssertFalse(service.isSignedIn)
        try await service.restoreSavedSession()
        XCTAssertTrue(service.isSignedIn)
        XCTAssertEqual(service.accountLabel, saved.label)
        XCTAssertEqual(storage.loads, 1)
        XCTAssertEqual(storage.saves, 0)
        XCTAssertEqual(fixture.metadata.reads, 0)
        XCTAssertEqual(fixture.authorizations, 0)
        let state = await fixture.store.uiState()
        XCTAssertEqual(state.credentials?.accessToken, saved.accessToken)
    }

    @MainActor
    func testExplicitResumeRejectsMissingBlockedAndCorruptRecords() async throws {
        let errors: [Error?] = [nil, CredentialCleanupError.deletionFailed(restorationBlocked: true, status: -25308), PlanError.service("synthetic_corrupt")]
        for failure in errors {
            let storage = CoordinatorCredentialStorage(initial: failure == nil ? nil : coordinatorCredentials("saved"))
            storage.setLoadError(failure)
            let fixture = CoordinatorFixture(storage: storage)
            let service = fixture.service()
            do { try await service.restoreSavedSession(); XCTFail("Invalid saved session activated") }
            catch { XCTAssertEqual(error as? PlanError, .service("no_saved_session")) }
            XCTAssertFalse(service.isSignedIn)
            XCTAssertFalse(service.isSigningIn)
            XCTAssertEqual(storage.loads, 1)
            XCTAssertEqual(service.needsLocalCleanupRetry, failure != nil)
            if failure != nil { XCTAssertNotNil(service.signOutNotice) }
            let state = await fixture.store.uiState()
            XCTAssertNil(state.credentials)
            XCTAssertEqual(fixture.authorizations, 0)
        }
    }

    @MainActor
    func testTokenWaitCancelAndTaskCancelCannotActivateOrPersistLateSuccess() async throws {
        for taskCancellation in [false, true] {
            let fixture = CoordinatorFixture()
            await fixture.effects.setHoldToken(true)
            let service = fixture.service()
            let operation = Task { try await service.signIn() }
            try await coordinatorEventually { await fixture.effects.pendingTokenCount == 1 }
            if taskCancellation { operation.cancel() } else { service.cancelSignIn() }
            await fixture.effects.releaseToken(0)
            await expectCoordinatorCancellation(operation)
            XCTAssertFalse(service.isSignedIn)
            XCTAssertFalse(service.isSigningIn)
            XCTAssertEqual(fixture.storage.saves, 0)
            XCTAssertNil(fixture.storage.saved)
            XCTAssertNil(fixture.metadata.savedRegistration)
            let identityCalls = await fixture.effects.identityCount
            XCTAssertEqual(identityCalls, 0, "Cancelled token stage must not start identity validation")
            let state = await fixture.store.uiState()
            XCTAssertNil(state.credentials)
        }
    }

    @MainActor
    func testIdentityJWKSWaitBackgroundCancelAndTaskCancelCannotActivateLateSuccess() async throws {
        for taskCancellation in [false, true] {
            let fixture = CoordinatorFixture()
            await fixture.effects.setHoldIdentity(true)
            let service = fixture.service()
            let operation = Task { try await service.signIn() }
            try await coordinatorEventually { await fixture.effects.pendingIdentityCount == 1 }
            // Production VM calls cancelSignIn when it backgrounds; UIKit delivery is a
            // separate UI test. Here the real coordinator receives that same cancellation.
            if taskCancellation { operation.cancel() } else { service.cancelSignIn() }
            await fixture.effects.releaseIdentity(0)
            await expectCoordinatorCancellation(operation)
            XCTAssertFalse(service.isSignedIn)
            XCTAssertFalse(service.isSigningIn)
            XCTAssertEqual(fixture.storage.saves, 0)
            XCTAssertNil(fixture.storage.saved)
            XCTAssertNil(fixture.metadata.savedRegistration)
            let state = await fixture.store.uiState()
            XCTAssertNil(state.credentials)
        }
    }

    @MainActor
    func testCancelledTokenOrIdentityCompletionCannotOverwriteNewSuccessfulLogin() async throws {
        for identityStage in [false, true] {
            let fixture = CoordinatorFixture()
            if identityStage { await fixture.effects.setHoldIdentity(true) }
            else { await fixture.effects.setHoldToken(true) }
            let service = fixture.service()
            let old = Task { try await service.signIn() }
            try await coordinatorEventually {
                if identityStage { return await fixture.effects.pendingIdentityCount == 1 }
                return await fixture.effects.pendingTokenCount == 1
            }
            service.cancelSignIn()
            await fixture.effects.setHoldToken(false); await fixture.effects.setHoldIdentity(false)
            try await service.signIn()
            let current = try XCTUnwrap(fixture.storage.saved)
            XCTAssertTrue(service.isSignedIn)
            if identityStage { await fixture.effects.releaseIdentity(0) }
            else { await fixture.effects.releaseToken(0) }
            await expectCoordinatorCancellation(old)
            XCTAssertTrue(service.isSignedIn)
            XCTAssertEqual(service.accountLabel, current.label)
            XCTAssertEqual(fixture.storage.saved?.accessToken, current.accessToken)
            XCTAssertEqual(fixture.storage.saves, 1)
            let state = await fixture.store.uiState()
            XCTAssertEqual(state.credentials?.accessToken, current.accessToken)
        }
    }

    @MainActor
    func testCancelledLateTokenAndIdentityFailuresCannotModifyNewSuccessfulLogin() async throws {
        for identityStage in [false, true] {
            let fixture = CoordinatorFixture()
            if identityStage { await fixture.effects.setHoldIdentity(true) }
            else { await fixture.effects.setHoldToken(true) }
            let service = fixture.service()
            let old = Task { try await service.signIn() }
            try await coordinatorEventually {
                if identityStage { return await fixture.effects.pendingIdentityCount == 1 }
                return await fixture.effects.pendingTokenCount == 1
            }
            service.cancelSignIn()
            await fixture.effects.setHoldToken(false); await fixture.effects.setHoldIdentity(false)
            try await service.signIn()
            let current = try XCTUnwrap(fixture.storage.saved)
            let registration = fixture.metadata.savedRegistration
            let cancellations = fixture.cancellations
            let failure = PlanError.service("synthetic_late_failure")
            if identityStage { await fixture.effects.releaseIdentity(0, failure: failure) }
            else { await fixture.effects.releaseToken(0, failure: failure) }
            do { try await old.value; XCTFail("Old failed stage unexpectedly succeeded") }
            catch { XCTAssertEqual(error as? PlanError, failure) }
            XCTAssertTrue(service.isSignedIn)
            XCTAssertFalse(service.isSigningIn)
            XCTAssertNil(service.signOutNotice)
            XCTAssertEqual(service.accountLabel, current.label)
            XCTAssertEqual(fixture.storage.saved?.accessToken, current.accessToken)
            XCTAssertEqual(fixture.storage.saves, 1)
            XCTAssertEqual(fixture.metadata.savedRegistration?.clientID, registration?.clientID)
            XCTAssertEqual(fixture.metadata.savedRegistration?.subject, registration?.subject)
            XCTAssertEqual(fixture.cancellations, cancellations)
            let state = await fixture.store.uiState()
            XCTAssertEqual(state.credentials?.accessToken, current.accessToken)
        }
    }

    @MainActor
    func testDuplicateOAuthAndResumeAreRejectedWhileTokenRequestIsPending() async throws {
        let fixture = CoordinatorFixture()
        await fixture.effects.setHoldToken(true)
        let service = fixture.service()
        let operation = Task { try await service.signIn() }
        try await coordinatorEventually { await fixture.effects.pendingTokenCount == 1 }
        do { try await service.signIn(); XCTFail("Duplicate sign-in started") }
        catch { XCTAssertEqual(error as? PlanError, .service("sign_in_in_progress")) }
        do { try await service.restoreSavedSession(); XCTFail("Resume overlapped OAuth") }
        catch { XCTAssertEqual(error as? PlanError, .service("sign_in_in_progress")) }
        XCTAssertEqual(fixture.authorizations, 1)
        await service.signOut()
        await fixture.effects.releaseToken(0)
        await expectCoordinatorCancellation(operation)
        XCTAssertFalse(service.isSignedIn)
        XCTAssertEqual(fixture.storage.saves, 0)
        XCTAssertNil(fixture.storage.saved)
    }

    @MainActor
    func testOAuthAndSecondResumeCannotEnterDuringActualStoreRestore() async throws {
        let storage = CoordinatorCredentialStorage(initial: coordinatorCredentials("saved"))
        storage.armLoadBlock()
        let fixture = CoordinatorFixture(storage: storage)
        let service = fixture.service()
        let restoring = Task { try await service.restoreSavedSession() }
        defer { storage.releaseLoad() }
        try await coordinatorEventually { storage.loadEntered }
        XCTAssertTrue(service.isSigningIn)
        do { try await service.signIn(); XCTFail("OAuth overlapped actual restore") }
        catch { XCTAssertEqual(error as? PlanError, .service("sign_in_in_progress")) }
        do { try await service.restoreSavedSession(); XCTFail("Duplicate restore started") }
        catch { XCTAssertEqual(error as? PlanError, .service("sign_in_in_progress")) }
        storage.releaseLoad()
        try await restoring.value
        XCTAssertTrue(service.isSignedIn)
        await service.signOut()
        XCTAssertFalse(service.isSignedIn)
        XCTAssertNil(storage.saved)
        let cold = fixture.service()
        await coordinatorDrain()
        XCTAssertFalse(cold.isSignedIn)
        XCTAssertEqual(storage.loads, 1, "Cold construction must not restore after sign-out")
    }

    @MainActor
    func testAuthorizationCallbackIsStillValidatedByActualCoordinator() async throws {
        let fixture = CoordinatorFixture()
        fixture.invalidCallback = true
        let service = fixture.service()
        do { try await service.signIn(); XCTFail("Bad state accepted") }
        catch { XCTAssertEqual(error as? PlanError, .invalidCallback) }
        let tokenCalls = await fixture.effects.tokenCount
        XCTAssertEqual(tokenCalls, 0)
        XCTAssertEqual(fixture.storage.saves, 0)
        XCTAssertNil(fixture.metadata.savedPending)
        fixture.invalidCallback = false
        try await service.signIn()
        XCTAssertTrue(service.isSignedIn)
        let capturedFields = await fixture.effects.lastTokenFields()
        let fields = try XCTUnwrap(capturedFields)
        let attempt = try XCTUnwrap(fixture.lastAttempt)
        XCTAssertEqual(fields["code_verifier"], attempt.verifier)
        XCTAssertEqual(fields["client_id"], "synthetic-client")
        let validation = await fixture.effects.lastIdentityArguments()
        XCTAssertEqual(validation?.clientID, "synthetic-client")
        XCTAssertEqual(validation?.nonce, attempt.nonce)
    }

    @MainActor
    func testRealStoreInvalidationPublishesVisibleReauthenticationReasonAfterSuccessfulCleanup() async throws {
        let fixture = CoordinatorFixture(notifications: .default)
        let service = fixture.service()
        try await service.signIn()
        await fixture.store.invalidate()
        try await coordinatorEventually { !service.isSignedIn && service.signOutNotice != nil }
        XCTAssertEqual(service.localCleanupState, .removed)
        XCTAssertTrue(service.signOutNotice?.contains("已失效") == true)
        XCTAssertTrue(service.signOutNotice?.contains("expired or was revoked") == true)
        XCTAssertNil(fixture.storage.saved)
    }

    @MainActor
    func testLateInvalidationNotificationDoesNotClearNewSuccessfulLogin() async throws {
        let fixture = CoordinatorFixture()
        let service = fixture.service()
        try await service.signIn()
        let current = try XCTUnwrap(fixture.storage.saved)
        let lookups = fixture.storeLookups.value
        // This deliberately tests the observer itself with an isolated notification center.
        // Real Store -> default NotificationCenter delivery is covered by the preceding test.
        fixture.notifications.post(name: .chatGPTReauthenticationRequired, object: nil)
        try await coordinatorEventually { fixture.storeLookups.value > lookups }
        await coordinatorDrain()
        XCTAssertTrue(service.isSignedIn)
        XCTAssertEqual(service.accountLabel, current.label)
        XCTAssertEqual(fixture.storage.saved?.accessToken, current.accessToken)
    }
}

@MainActor
private final class CoordinatorFixture {
    let storage: CoordinatorCredentialStorage
    let store: ChatGPTSessionStore
    let metadata = CoordinatorMetadata()
    let effects = CoordinatorEffects()
    let notifications: NotificationCenter
    let storeLookups = CoordinatorCounter()
    var authorizations = 0
    var cancellations = 0
    var invalidCallback = false
    var lastAttempt: SignInAttempt?
    init(storage: CoordinatorCredentialStorage = CoordinatorCredentialStorage(initial: nil), notifications: NotificationCenter = NotificationCenter()) {
        self.notifications = notifications
        self.storage = storage
        store = ChatGPTSessionStore(storage: storage, refreshOperation: { _ in throw PlanError.service("unexpected_fixture_refresh") }, revocationOperation: { _ in true })
    }
    func service() -> ChatGPTAccountService {
        let store = store, counter = storeLookups, effects = effects
        let dependencies = AccountCoordinatorDependencies(store: { counter.increment(); return store }, metadata: metadata,
            tokenRequest: { try await effects.token($0) }, validated: { try await effects.identity($0, clientID: $1, nonce: $2) },
            authorization: { [self] host, client in
                authorizations += 1
                let attempt = SignInAttempt(hostID: host, port: 1455, clientID: client)
                lastAttempt = attempt
                return AccountAuthorizationResponse(attempt: attempt, query: [
                    .init(name: "state", value: invalidCallback ? "wrong" : attempt.state),
                    .init(name: "code", value: "synthetic-code-\(authorizations)"), .init(name: "client_id", value: "synthetic-client")])
            }, cancelAuthorization: { [weak self] in self?.cancellations += 1 }, notifications: notifications)
        return ChatGPTAccountService(dependencies: dependencies)
    }
}

@MainActor
private final class CoordinatorMetadata: AccountRegistrationStorage {
    private var savedHost: String?
    var savedRegistration: PlanRegistration?
    var savedPending: PendingPlanRegistration?
    var reads = 0
    func hostID() throws -> String? { reads += 1; return savedHost }
    func saveHostID(_ value: String) throws { savedHost = value }
    func registration() throws -> PlanRegistration? { reads += 1; return savedRegistration }
    func saveRegistration(_ value: PlanRegistration) throws { savedRegistration = value }
    func pendingRegistration() throws -> PendingPlanRegistration? { reads += 1; return savedPending }
    func savePendingRegistration(_ value: PendingPlanRegistration) throws { savedPending = value }
    func clearPendingRegistration() throws { savedPending = nil }
}

private final class CoordinatorCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class CoordinatorCredentialStorage: PlanCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PlanCredentials?
    private var loadFailure: Error?
    private var loadCount = 0, saveCount = 0
    private var blockLoad = false, enteredLoad = false
    private let loadRelease = DispatchSemaphore(value: 0)
    init(initial: PlanCredentials?) { value = initial }
    var saved: PlanCredentials? { lock.lock(); defer { lock.unlock() }; return value }
    var loads: Int { lock.lock(); defer { lock.unlock() }; return loadCount }
    var saves: Int { lock.lock(); defer { lock.unlock() }; return saveCount }
    var loadEntered: Bool { lock.lock(); defer { lock.unlock() }; return enteredLoad }
    func setLoadError(_ error: Error?) { lock.lock(); loadFailure = error; lock.unlock() }
    func armLoadBlock() { lock.lock(); blockLoad = true; lock.unlock() }
    func releaseLoad() { loadRelease.signal() }
    func load() throws -> PlanCredentials? {
        lock.lock(); loadCount += 1
        let block = blockLoad; blockLoad = false; enteredLoad = block
        let failure = loadFailure, current = value
        lock.unlock()
        if block { _ = loadRelease.wait(timeout: .now() + 3) }
        if let failure { throw failure }
        return current
    }
    func save(_ credentials: PlanCredentials) throws { lock.lock(); value = credentials; saveCount += 1; lock.unlock() }
    func clear() throws { lock.lock(); value = nil; lock.unlock() }
}

/// Intentionally noncooperative: late HTTP/identity effects may succeed after cancellation.
private actor CoordinatorEffects {
    struct IdentityArguments: Sendable { let clientID: String; let nonce: String? }
    private var holdToken = false, holdIdentity = false
    private var tokens: [[String: String]] = []
    private var identities: [(TokenReply, IdentityArguments)] = []
    private var tokenWaiters: [Int: CheckedContinuation<TokenReply, Error>] = [:]
    private var identityWaiters: [Int: CheckedContinuation<PlanCredentials, Error>] = [:]
    var tokenCount: Int { tokens.count }
    var identityCount: Int { identities.count }
    var pendingTokenCount: Int { tokenWaiters.count }
    var pendingIdentityCount: Int { identityWaiters.count }
    func setHoldToken(_ value: Bool) { holdToken = value }
    func setHoldIdentity(_ value: Bool) { holdIdentity = value }
    func lastTokenFields() -> [String: String]? { tokens.last }
    func lastIdentityArguments() -> IdentityArguments? { identities.last?.1 }
    func token(_ fields: [String: String]) async throws -> TokenReply {
        let index = tokens.count; tokens.append(fields)
        if holdToken { return try await withCheckedThrowingContinuation { tokenWaiters[index] = $0 } }
        return try tokenReply(index)
    }
    func identity(_ reply: TokenReply, clientID: String, nonce: String?) async throws -> PlanCredentials {
        let index = identities.count
        identities.append((reply, IdentityArguments(clientID: clientID, nonce: nonce)))
        if holdIdentity { return try await withCheckedThrowingContinuation { identityWaiters[index] = $0 } }
        return identityResult(index)
    }
    func releaseToken(_ index: Int, failure: PlanError? = nil) {
        if let continuation = tokenWaiters.removeValue(forKey: index) {
            if let failure { continuation.resume(throwing: failure) }
            else { continuation.resume(with: Result { try tokenReply(index) }) }
        }
    }
    func releaseIdentity(_ index: Int, failure: PlanError? = nil) {
        if let continuation = identityWaiters.removeValue(forKey: index) {
            if let failure { continuation.resume(throwing: failure) }
            else { continuation.resume(returning: identityResult(index)) }
        }
    }
    private func tokenReply(_ index: Int) throws -> TokenReply {
        try JSONDecoder().decode(TokenReply.self, from: JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-access-\(tokens[index]["code"] ?? "missing")", "refresh_token": "synthetic-refresh",
            "id_token": "synthetic-id", "scope": SubscriptionContract.scopes, "token_type": "Bearer", "expires_in": 3600]))
    }
    private func identityResult(_ index: Int) -> PlanCredentials {
        let (reply, arguments) = identities[index]
        return .init(clientID: arguments.clientID, subject: "synthetic-subject", label: reply.access_token,
            accessToken: reply.access_token, refreshToken: reply.refresh_token, idToken: reply.id_token ?? "synthetic-id",
            scopes: reply.scope ?? SubscriptionContract.scopes, expiresAt: Date().addingTimeInterval(3600))
    }
}

private func coordinatorCredentials(_ name: String) -> PlanCredentials {
    .init(clientID: "synthetic-client", subject: "synthetic-subject", label: "Saved " + name,
          accessToken: "synthetic-access-" + name, refreshToken: "synthetic-refresh", idToken: "synthetic-id",
          scopes: SubscriptionContract.scopes, expiresAt: Date().addingTimeInterval(3600))
}

@MainActor
private func coordinatorEventually(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<500 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Timed out waiting for actual account coordinator")
    throw PlanError.service("coordinator_fixture_timeout")
}
@MainActor
private func coordinatorDrain() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(5)) }
@MainActor
private func expectCoordinatorCancellation(_ operation: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await operation.value; XCTFail("Late cancelled authorization completed", file: file, line: line) }
    catch { XCTAssertTrue(error is CancellationError || error as? PlanError == .denied, "\(error)", file: file, line: line) }
}
