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
    private var session: ASWebAuthenticationSession?
    private var listener: PlanLoopbackListener?
    private var pending: PlanCallbackWaiter?
    private var timeout: Task<Void, Never>?
    private var invalidationObserver: NSObjectProtocol?
    private var signInGeneration = 0

    init(restoreSession: Bool = true) {
        super.init()
        invalidationObserver = NotificationCenter.default.addObserver(forName: .chatGPTReauthenticationRequired, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isSignedIn = false; self?.accountLabel = "" }
        }
        guard restoreSession else { return }
        Task {
            if let value = await ChatGPTSessionStore.shared.snapshot() {
                guard signInGeneration == 0 else { return }
                isSignedIn = true; accountLabel = value.label
            }
        }
    }

    func signIn() async throws {
        guard !isSigningIn else { throw PlanError.service("sign_in_in_progress") }
        signInGeneration += 1
        let expectedGeneration = signInGeneration
        isSigningIn = true
        defer {
            if signInGeneration == expectedGeneration { isSigningIn = false; cleanup() }
        }
        let hostID: String
        if let saved = try KeychainRecord.read(String.self, key: "host-id-v1") { hostID = saved }
        else {
            hostID = "urn:uuid:" + UUID().uuidString.lowercased()
            try KeychainRecord.write(hostID, key: "host-id-v1")
        }
        let previous = try KeychainRecord.read(PlanRegistration.self, key: "chatgpt-registration-v1")
        let unfinished = try KeychainRecord.read(PendingPlanRegistration.self, key: "chatgpt-pending-registration-v1")
        let listener = try PlanLoopbackListener()
        self.listener = listener
        defer { listener.stop() }
        let port = try await listener.start()
        try ensureCurrent(expectedGeneration)
        let attempt = SignInAttempt(hostID: hostID, port: port, clientID: previous?.clientID ?? unfinished?.clientID)
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
        try ensureCurrent(expectedGeneration)
        let callback = try attempt.callback(query)
        // Retain the issued client before exchange so invalid_grant recovery reuses registration.
        // This is pending registration metadata, not a verified identity or an active account.
        try KeychainRecord.write(PendingPlanRegistration(clientID: callback.clientID), key: "chatgpt-pending-registration-v1")
        let reply = try await ChatGPTSessionStore.tokenRequest(["grant_type": "authorization_code", "client_id": callback.clientID,
            "code": callback.code, "code_verifier": attempt.verifier, "redirect_uri": attempt.redirectURI,
            "resource": SubscriptionContract.resource])
        try ensureCurrent(expectedGeneration)
        let credentials = try await ChatGPTSessionStore.validated(reply, clientID: callback.clientID, nonce: attempt.nonce)
        try ensureCurrent(expectedGeneration)
        if let previous, previous.subject != credentials.subject { throw PlanError.invalidIdentity }
        try KeychainRecord.write(PlanRegistration(clientID: credentials.clientID, subject: credentials.subject), key: "chatgpt-registration-v1")
        try Task.checkCancellation()
        try await ChatGPTSessionStore.shared.save(credentials)
        do { try ensureCurrent(expectedGeneration) }
        catch {
            await ChatGPTSessionStore.shared.discardIfMatching(credentials.accessToken)
            throw error
        }
        isSignedIn = true; accountLabel = credentials.label; signOutNotice = nil
        KeychainRecord.delete(key: "chatgpt-pending-registration-v1")
    }

    /// Called when the user cancels or the app leaves the active foreground.
    func cancelSignIn() {
        signInGeneration += 1
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
        let revoked = await ChatGPTSessionStore.shared.signOut()
        guard signInGeneration == expectedGeneration else { return }
        signOutNotice = revoked ? nil : "Local credentials were removed. Remote revocation was not confirmed; disconnect OpenVision in ChatGPT Settings."
    }

    private func cleanup() {
        timeout?.cancel(); timeout = nil
        listener?.stop(); listener = nil
        session?.cancel(); session = nil
        pending = nil
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

private struct PlanRegistration: Codable { let clientID: String; let subject: String }
private struct PendingPlanRegistration: Codable { let clientID: String }
