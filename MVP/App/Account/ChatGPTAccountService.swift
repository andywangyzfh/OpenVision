import Foundation
import Combine
import AuthenticationServices
import UIKit
import SubscriptionCore

@MainActor
final class ChatGPTAccountService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var isSignedIn = false
    @Published private(set) var accountLabel = ""
    @Published private(set) var signOutNotice: String?
    @Published private(set) var isSigningIn = false
    @Published private(set) var localCleanupState: LocalCredentialCleanup = .notChecked
    private var session: ASWebAuthenticationSession?
    private var listener: PlanLoopbackListener?
    private var pending: PlanCallbackWaiter?
    private var timeout: Task<Void, Never>?
    private var invalidationObserver: NSObjectProtocol?
    private var signInGeneration = 0
    private var authorizationPermit: PlanAuthorizationPermit?
    private let dependencies: AccountCoordinatorDependencies
    private var store: ChatGPTSessionStore { dependencies.store() }
    private var identityUIRevision = 0
    var needsLocalCleanupRetry: Bool {
        switch localCleanupState {
        case .blockedPendingDeletion, .unsafeFailure: return true
        case .removed, .notChecked: return false
        }
    }

    init(dependencies: AccountCoordinatorDependencies? = nil) {
        self.dependencies = dependencies ?? .live()
        super.init()
        invalidationObserver = self.dependencies.notifications.addObserver(forName: .chatGPTReauthenticationRequired, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let expectedGeneration = self.signInGeneration
                let expectedUIRevision = self.identityUIRevision
                let state = await self.store.uiState()
                guard self.signInGeneration == expectedGeneration, self.identityUIRevision == expectedUIRevision else { return }
                self.localCleanupState = state.cleanup
                // A late notification must neither activate saved credentials nor clear a newer
                // completed login. Always reconcile with the current atomic Store snapshot.
                if let value = state.credentials {
                    if self.isSignedIn { self.accountLabel = value.label }
                } else {
                    self.isSignedIn = false; self.accountLabel = ""
                    self.signOutNotice = self.needsLocalCleanupRetry
                        ? Self.notice(for: SessionSignOutResult(local: state.cleanup, remote: .unconfirmed))
                        : "订阅登录已失效，请重新登录 ChatGPT。\nYour plan sign-in expired or was revoked. Sign in to ChatGPT again."
                }
                self.identityUIRevision += 1
            }
        }
        // No startup read/probe, including when an old credential cannot be deleted. A saved
        // sign-in is considered only after the user explicitly calls restoreSavedSession().
    }

    func restoreSavedSession() async throws {
        guard !isSigningIn else { throw PlanError.service("sign_in_in_progress") }
        signInGeneration += 1
        let expectedGeneration = signInGeneration
        let permit = PlanAuthorizationPermit()
        authorizationPermit = permit; isSigningIn = true
        defer {
            permit.cancel()
            if signInGeneration == expectedGeneration { isSigningIn = false; cleanup() }
        }
        let epoch = await store.authorizationEpoch()
        try ensureCurrent(expectedGeneration)
        let state = try await store.resumeSavedCredentials(expectedEpoch: epoch, authorization: permit)
        do { try ensureCurrent(expectedGeneration) }
        catch {
            if let value = state.credentials {
                await store.discardIfMatching(value.accessToken, expectedEpoch: state.epoch)
            }
            throw error
        }
        localCleanupState = state.cleanup; identityUIRevision += 1
        guard let value = state.credentials else {
            signOutNotice = needsLocalCleanupRetry
                ? Self.notice(for: SessionSignOutResult(local: state.cleanup, remote: .unconfirmed))
                : "没有可恢复的本机登录，请重新登录。\nNo saved sign-in is available. Sign in again."
            throw PlanError.service("no_saved_session")
        }
        isSignedIn = true; accountLabel = value.label
        signOutNotice = nil
    }

    func signIn() async throws {
        guard !isSigningIn else { throw PlanError.service("sign_in_in_progress") }
        signInGeneration += 1
        let expectedGeneration = signInGeneration
        let permit = PlanAuthorizationPermit()
        authorizationPermit = permit
        isSigningIn = true
        defer {
            permit.cancel()
            if signInGeneration == expectedGeneration { isSigningIn = false; cleanup() }
        }
        let commitEpoch = await store.authorizationEpoch()
        try ensureCurrent(expectedGeneration)
        let hostID: String
        if let saved = try dependencies.metadata.hostID() { hostID = saved }
        else {
            hostID = "urn:uuid:" + UUID().uuidString.lowercased()
            try dependencies.metadata.saveHostID(hostID)
        }
        let previous = try dependencies.metadata.registration()
        let unfinished = try dependencies.metadata.pendingRegistration()
        let response: AccountAuthorizationResponse
        if let authorization = dependencies.authorization {
            response = try await authorization(hostID, previous?.clientID ?? unfinished?.clientID)
        } else {
            response = try await receiveAuthorization(hostID: hostID, clientID: previous?.clientID ?? unfinished?.clientID, expectedGeneration: expectedGeneration)
        }
        let attempt = response.attempt
        let query = response.query
        try ensureCurrent(expectedGeneration)
        let callback = try attempt.callback(query)
        // Retain the issued client before exchange so invalid_grant recovery reuses registration.
        // This is pending registration metadata, not a verified identity or an active account.
        try dependencies.metadata.savePendingRegistration(PendingPlanRegistration(clientID: callback.clientID))
        let reply = try await dependencies.tokenRequest(["grant_type": "authorization_code", "client_id": callback.clientID,
            "code": callback.code, "code_verifier": attempt.verifier, "redirect_uri": attempt.redirectURI,
            "resource": SubscriptionContract.resource])
        try ensureCurrent(expectedGeneration)
        let credentials = try await dependencies.validated(reply, callback.clientID, attempt.nonce)
        try ensureCurrent(expectedGeneration)
        if let previous, previous.subject != credentials.subject { throw PlanError.invalidIdentity }
        try dependencies.metadata.saveRegistration(PlanRegistration(clientID: credentials.clientID, subject: credentials.subject))
        try Task.checkCancellation()
        try await store.save(credentials, expectedEpoch: commitEpoch, authorization: permit)
        do { try ensureCurrent(expectedGeneration) }
        catch {
            await store.discardIfMatching(credentials.accessToken, expectedEpoch: commitEpoch + 1)
            throw error
        }
        isSignedIn = true; accountLabel = credentials.label; identityUIRevision += 1; signOutNotice = nil; localCleanupState = .removed
        // Pending registration contains no secrets; a retained copy is safe to reuse.
        try? dependencies.metadata.clearPendingRegistration()
    }

    private func receiveAuthorization(hostID: String, clientID: String?, expectedGeneration: Int) async throws -> AccountAuthorizationResponse {
        let listener = try PlanLoopbackListener()
        self.listener = listener
        let port = try await listener.start()
        try ensureCurrent(expectedGeneration)
        let attempt = SignInAttempt(hostID: hostID, port: port, clientID: clientID)
        listener.expectedState = attempt.state
        let waiter = PlanCallbackWaiter()
        pending = waiter
        listener.onQuery = { query in waiter.complete(.success(query)) }
        listener.onFailure = { waiter.complete(.failure(PlanError.service("callback_listener_failed"))) }
        let browser = ASWebAuthenticationSession(url: attempt.authorizationURL, callbackURLScheme: nil) { _, _ in
            waiter.complete(.failure(PlanError.denied))
        }
        browser.presentationContextProvider = self
        session = browser
        guard browser.start() else { throw PlanError.service("browser_unavailable") }
        timeout = Task {
            do {
                try await Task.sleep(for: .seconds(300))
                waiter.complete(.failure(PlanError.service("sign_in_timeout")))
            } catch { }
        }
        let query = try await withTaskCancellationHandler(operation: { try await waiter.result() }, onCancel: {
            waiter.complete(.failure(CancellationError()))
        })
        return AccountAuthorizationResponse(attempt: attempt, query: query)
    }

    /// Called when the user cancels or the app leaves the active foreground.
    func cancelSignIn() {
        signInGeneration += 1
        authorizationPermit?.cancel(); authorizationPermit = nil
        isSigningIn = false
        pending?.complete(.failure(PlanError.denied))
        cleanup()
    }

    private func ensureCurrent(_ expected: Int) throws {
        try Task.checkCancellation()
        guard expected == signInGeneration else { throw CancellationError() }
    }

    func signOut() async {
        cancelSignIn()
        isSignedIn = false; accountLabel = ""
        let expectedGeneration = signInGeneration
        let result = await store.signOut()
        guard signInGeneration == expectedGeneration else { return }
        localCleanupState = result.local; identityUIRevision += 1
        signOutNotice = Self.notice(for: result)
    }

    func retryLocalCleanup() async {
        let expectedGeneration = signInGeneration
        let result = await store.retryLocalCleanup()
        guard signInGeneration == expectedGeneration else { return }
        localCleanupState = result.local; identityUIRevision += 1
        signOutNotice = Self.notice(for: result)
    }

    private static func notice(for result: SessionSignOutResult) -> String? {
        guard !result.complete else { return nil }
        let local: String
        switch result.local {
        case .notChecked:
            local = "尚未检查本机保存的登录。\nSaved local credentials have not been inspected."
        case .removed:
            local = "本机凭据已删除。\nLocal credentials were deleted."
        case .blockedPendingDeletion:
            local = "本机凭据删除失败，已持久阻止重新启动恢复。请重试本机清理。\nLocal credential deletion failed. A persistent block prevents restoration after restart. Retry local cleanup."
        case .unsafeFailure:
            local = "凭据删除与持久禁用未确认，不能视为记录已清除；请重试清理。\nLocal credential deletion and persistent disablement were not confirmed. Do not treat the record as erased; retry local cleanup."
        }
        let remote: String
        switch result.remote {
        case .confirmed: remote = "远程撤销已确认。\nRemote revocation was confirmed."
        case .notNeeded: remote = "此登录没有可撤销的续期令牌，未执行远程撤销。\nNo renewable token was available; no remote revocation request was made."
        case .unconfirmed: remote = "远程撤销尚未确认，请在 ChatGPT 设置中断开 OpenVision。\nRemote revocation was not confirmed. Disconnect OpenVision in ChatGPT Settings."
        }
        return local + "\n" + remote
    }

    private func cleanup() {
        dependencies.cancelAuthorization()
        timeout?.cancel(); timeout = nil
        listener?.stop(); listener = nil
        session?.cancel(); session = nil
        pending = nil
        authorizationPermit = nil
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
