import Foundation
import Combine
import AuthenticationServices
import UIKit
import Network
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

    override init() {
        super.init()
        invalidationObserver = NotificationCenter.default.addObserver(forName: .chatGPTReauthenticationRequired, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isSignedIn = false; self?.accountLabel = "" }
        }
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

/// Stores an early callback as well as handling cancellation before continuation installation.
private final class PlanCallbackWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[URLQueryItem], Error>?
    private var outcome: Result<[URLQueryItem], Error>?
    func result() async throws -> [URLQueryItem] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let outcome { lock.unlock(); continuation.resume(with: outcome) }
            else { self.continuation = continuation; lock.unlock() }
        }
    }
    func complete(_ result: Result<[URLQueryItem], Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let continuation = continuation; self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class PlanLoopbackListener: @unchecked Sendable {
    var expectedState = ""
    var onQuery: (([URLQueryItem]) -> Void)?
    var onFailure: (() -> Void)?
    private let listener: NWListener
    private let queue = DispatchQueue(label: "openvision.plan-loopback")
    private var ready: CheckedContinuation<UInt16, Error>?
    private var connections: [NWConnection] = []
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = self.listener.port { self.ready?.resume(returning: port.rawValue); self.ready = nil }
                case .failed:
                    self.ready?.resume(throwing: PlanError.service("callback_listener_failed")); self.ready = nil
                    self.onFailure?()
                case .cancelled:
                    self.ready?.resume(throwing: CancellationError()); self.ready = nil
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
            }
        }, onCancel: { self.stop() })
    }
    func stop() {
        queue.async { [self] in
            listener.cancel(); connections.forEach { $0.cancel() }; connections.removeAll()
        }
    }
    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var data = accumulated
            if let chunk { data.append(chunk) }
            if data.range(of: Data("\r\n\r\n".utf8)) == nil && !complete && error == nil && data.count < 32_768 {
                self.receive(connection, accumulated: data); return
            }
            let line = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            let target = parts.count == 3 && parts[0] == "GET" ? URLComponents(string: String(parts[1])) : nil
            let query = target?.queryItems ?? []
            let states = query.filter { $0.name == "state" }
            let valid = target?.path == "/auth/callback" && states.count == 1 && states.first?.value == self.expectedState
            let body = valid ? "Return to OpenVision to finish sign-in." : "Not found"
            let response = "HTTP/1.1 \(valid ? "200 OK" : "404 Not Found")\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if valid { self.onQuery?(query) }
        }
    }
}
