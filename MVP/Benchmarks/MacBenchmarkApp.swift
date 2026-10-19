import AppKit
import AuthenticationServices
import Foundation
import OpenVisionCore
import SubscriptionCore

// Only satisfies the unused production convenience initializer's type reference. This target
// always injects its own in-memory session; it never constructs the iPhone account service.
@MainActor final class ChatGPTAccountService {}

final class BenchmarkMemoryStorage: PlanCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PlanCredentials?
    func load() throws -> PlanCredentials? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ credentials: PlanCredentials) throws { lock.lock(); defer { lock.unlock() }; value = credentials }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}

struct BenchmarkRegistration: Codable { let hostID: String; var clientID: String? }

@MainActor
final class BenchmarkController: NSObject, NSApplicationDelegate, NSWindowDelegate, ASWebAuthenticationPresentationContextProviding {
    private var window: NSWindow!
    private var label: NSTextField!
    private var authButton: NSButton!
    private var runButton: NSButton!
    private var cancelButton: NSButton!
    private var billingCheck: NSButton!
    private var session: ASWebAuthenticationSession?
    private let store = ChatGPTSessionStore(storage: BenchmarkMemoryStorage())
    private var operation: Task<Void, Never>?
    private lazy var lifecycle = BenchmarkLifecycle(store: store)
    private let ledger = BenchmarkRowLedger()
    private var terminating = false
    private var reportFolder: URL?
    private var models: [BenchmarkModel] { lifecycle.models }
    private var rows: [BenchmarkRow] { ledger.rows }
    private var didRun = false
    private var root: URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--work-root"), args.indices.contains(i + 1) { return URL(fileURLWithPath: args[i + 1]) }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("OpenVisionBenchmark")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 650, height: 430), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "OpenVision 本机性能测试"; window.center(); window.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        let title = NSTextField(labelWithString: "中文 / English / 上下文 / 公开合成图片")
        title.font = .boldSystemFont(ofSize: 18)
        let detail = NSTextField(wrappingLabelWithString: "只测 Mac 的真实接口，不开启手机、相机或麦克风。最多39次请求，比较3个模型；每项3次。使用独立官方登录，token仅留在本进程内存。不会购买额度或自动重试。")
        authButton = NSButton(title: "1. 官方登录 ChatGPT", target: self, action: #selector(signIn))
        let usage = NSButton(title: "2. 打开官方用量设置", target: self, action: #selector(openUsage))
        billingCheck = NSButton(checkboxWithTitle: "我已核对本次账号：只使用套餐额度，额外 credits 为0且自动充值关闭", target: self, action: #selector(updateControls))
        billingCheck.allowsMixedState = false
        billingCheck.isEnabled = false
        runButton = NSButton(title: "3. 开始本机模型比较（最多39次）", target: self, action: #selector(runBenchmark)); runButton.isEnabled = false
        cancelButton = NSButton(title: "停止当前测试", target: self, action: #selector(cancel)); cancelButton.isEnabled = false
        label = NSTextField(wrappingLabelWithString: "准备就绪，尚未登录或发送任何模型请求。")
        for view in [title, detail, authButton!, usage, billingCheck!, runButton!, cancelButton!, label!] { stack.addArrangedSubview(view) }
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
    @objc private func openUsage() { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/#settings/Usage")!) }
    @objc private func updateControls() {
        billingCheck.isEnabled = lifecycle.phase == .ready && operation == nil && !didRun && !terminating
        lifecycle.setBillingConfirmed(billingCheck.state == .on)
        authButton.isEnabled = lifecycle.canAuthorize && operation == nil && !didRun && !terminating
        runButton.isEnabled = lifecycle.authenticated && models.count == 3 && billingCheck.state == .on && operation == nil && !didRun && !terminating
    }
    private func resetAccountControls() {
        billingCheck.state = .off
        billingCheck.isEnabled = false
        runButton.isEnabled = false; authButton.isEnabled = false
    }
    private func finishOperation(owner: Int) {
        guard lifecycle.owns(owner), !terminating else { return }
        operation = nil; cancelButton.isEnabled = false; updateControls()
    }
    private func cleanSession(reason: String, owner: Int) async {
        guard lifecycle.owns(owner) else { return }
        let cleanupOwner = lifecycle.invalidate()
        resetAccountControls(); cancelButton.isEnabled = false
        let result = await lifecycle.finishCleanup(owner: cleanupOwner)
        guard lifecycle.owns(cleanupOwner) else { return }
        let cleanup = benchmarkCleanupMessage(result)
        recordCleanup(result)
        label.stringValue = reason + " " + cleanup
        finishOperation(owner: cleanupOwner)
    }
    private func recordCleanup(_ result: SessionSignOutResult) {
        let remote: String
        switch result.remote { case .confirmed: remote = "confirmed"; case .notNeeded: remote = "not_needed"; case .unconfirmed: remote = "unconfirmed" }
        let value: [String: Any] = ["memory_credentials_cleared": result.local == .removed, "remote_revocation": remote, "scope": "this Mac benchmark process only; no other app or device credentials accessed"]
        print(benchmarkCleanupMessage(result))
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: (reportFolder ?? root).appendingPathComponent("session-cleanup.json"), options: .atomic)
        } catch { print("Cleanup result could not be saved; remote status above remains authoritative for this process.") }
    }
    @objc private func signIn() {
        guard operation == nil, lifecycle.canAuthorize, !didRun, !terminating else { return }
        billingCheck.state = .off; billingCheck.isEnabled = false
        authButton.isEnabled = false; cancelButton.isEnabled = true
        operation = Task {
            var owner = lifecycle.generation
            do {
                let attempt = try await lifecycle.beginAuthorization(); owner = attempt.generation
                try await authorize(attempt)
                let available = try await catalog(owner: owner)
                try lifecycle.ensureCurrent(owner)
                let preferences = ["gpt-6-luna", "gpt-6-sol", "gpt-6.1-sol"]
                let selected = preferences.compactMap { slug in available.first { $0.slug == slug && $0.modalities?.contains("image") != false } }
                guard selected.count == 3 else { throw PlanError.service("catalog_candidates_unavailable") }
                try lifecycle.markReady(attempt, models: selected)
                billingCheck.state = .off
                label.stringValue = "官方授权与目录已完成。候选：\(models.map(\.slug).joined(separator: "、"))。请核对本次账号用量设置后，勾选并开始。未发送推理请求。"
                finishOperation(owner: owner)
            } catch {
                await cleanSession(reason: "尚未开始：\(benchmarkError(error))。账号/资格或目录不同，保持停止；不切换其他计费后端。", owner: owner)
            }
        }
    }
    private func authorize(_ authorization: BenchmarkAuthorizationAttempt) async throws {
        try lifecycle.ensureCurrent(authorization.generation)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let registrationURL = root.appendingPathComponent("registration.json")
        var registration: BenchmarkRegistration
        if FileManager.default.fileExists(atPath: registrationURL.path) { registration = try JSONDecoder().decode(BenchmarkRegistration.self, from: Data(contentsOf: registrationURL)) }
        else {
            registration = .init(hostID: "urn:uuid:" + UUID().uuidString.lowercased(), clientID: nil)
            try JSONEncoder().encode(registration).write(to: registrationURL, options: .atomic)
        }
        let listener = try PlanLoopbackListener(); let port = try await listener.start()
        let attempt = SignInAttempt(hostID: registration.hostID, port: port, clientID: registration.clientID)
        let waiter = PlanCallbackWaiter(); listener.expectedState = attempt.state
        listener.onQuery = { waiter.complete(.success($0)) }
        listener.onFailure = { waiter.complete(.failure(PlanError.service("callback_listener_failed"))) }
        let browser = ASWebAuthenticationSession(url: attempt.authorizationURL, callbackURLScheme: nil) { _, _ in waiter.complete(.failure(PlanError.denied)) }
        browser.presentationContextProvider = self; session = browser
        let timeout = Task { do { try await Task.sleep(for: .seconds(300)); waiter.complete(.failure(PlanError.service("sign_in_timeout"))) } catch {} }
        defer { timeout.cancel(); listener.stop(); browser.cancel(); if session === browser { session = nil } }
        try lifecycle.ensureCurrent(authorization.generation)
        guard browser.start() else { throw PlanError.service("browser_unavailable") }
        let query = try await withTaskCancellationHandler(operation: { try await waiter.result() }, onCancel: { waiter.complete(.failure(CancellationError())) })
        try lifecycle.ensureCurrent(authorization.generation)
        let callback = try attempt.callback(query)
        registration.clientID = callback.clientID
        try JSONEncoder().encode(registration).write(to: registrationURL, options: .atomic)
        let reply = try await ChatGPTSessionStore.tokenRequest(["grant_type": "authorization_code", "client_id": callback.clientID, "code": callback.code, "code_verifier": attempt.verifier, "redirect_uri": attempt.redirectURI, "resource": SubscriptionContract.resource])
        try lifecycle.ensureCurrent(authorization.generation)
        let credentials = try await ChatGPTSessionStore.validated(reply, clientID: callback.clientID, nonce: attempt.nonce)
        try lifecycle.ensureCurrent(authorization.generation)
        try await lifecycle.commit(credentials, attempt: authorization)
    }
    private func catalog(owner: Int) async throws -> [BenchmarkModel] {
        try lifecycle.ensureCurrent(owner)
        var request = URLRequest(url: URL(string: SubscriptionContract.resource + "/models")!)
        let token = try await store.accessToken()
        try lifecycle.ensureCurrent(owner)
        request.timeoutInterval = 30; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await PlanHTTPTransport.session.data(for: request)
        try lifecycle.ensureCurrent(owner)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let list = object["models"] as? [[String: Any]] else { throw PlanError.malformedResponse }
        return list.compactMap { row in
            guard row["visibility"] as? String == "list", let slug = row["slug"] as? String else { return nil }
            return .init(slug: slug, modalities: row["input_modalities"] as? [String])
        }
    }
    @objc private func runBenchmark() {
        guard operation == nil, lifecycle.authenticated, models.count == 3, billingCheck.state == .on, !didRun, !terminating else { return }
        let owner: Int
        do { owner = try lifecycle.beginRun() } catch { return }
        didRun = true; runButton.isEnabled = false; authButton.isEnabled = false; cancelButton.isEnabled = true
        operation = Task {
            let reason: String
            do {
                try await performBenchmark(owner: owner)
                reason = "本机试跑已完成并保存。还需审阅答案质量后才能建议模型；Mac 耗时不代表手机或眼镜实测。"
            } catch {
                if error is BenchmarkPersistenceFailure {
                    reason = "已停止：结果落盘失败，本次结果未确认保存。内存中每次请求仅有一条记录；没有自动重试。"
                } else {
                    reason = "已停止：\(benchmarkError(error))。已尝试保存完成与失败记录，无自动重试；请检查报告。"
                }
            }
            await cleanSession(reason: reason, owner: owner)
        }
    }
    private func performBenchmark(owner: Int) async throws {
        try lifecycle.ensureCurrent(owner)
        let suite = try BenchmarkSuite.fixtures()
        let runRoot = root.appendingPathComponent("run-" + UUID().uuidString.lowercased(), isDirectory: true)
        reportFolder = runRoot
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let candidates = models
        let schedule = try BenchmarkSchedule.make(modelCount: candidates.count, fixtureCount: suite.cases.count)
        let manifest: [String: Any] = ["schema": 1, "source": Bundle.main.object(forInfoDictionaryKey: "OpenVisionSource") as? String ?? "unknown", "scope": "Mac transport only; no microphone, phone, glasses or audible playback", "repetitions": 3, "max_requests": 39, "order": "balanced deterministic rotations v1; no RNG", "sequence": schedule.map { job in ["model": candidates[job.modelIndex].slug, "fixture": job.fixtureIndex == -1 ? suite.probe.id : suite.cases[job.fixtureIndex].id, "repetition": job.repetition] as [String: Any] }, "billing": "user attested current Mac account credits zero / automatic reload off; no purchase; post-run allocation not verified", "models": candidates.map { ["slug": $0.slug, "image_capability": $0.imageCapability] }, "fixtures": ([suite.probe] + suite.cases).map { ["id": $0.id, "prompt": $0.prompt, "instructions": $0.instructions, "image_sha256": BenchmarkSuite.imageHash($0.image) ?? "none", "context": $0.history.map { ["role": $0.role, "text": $0.text] }] as [String: Any] }]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: runRoot.appendingPathComponent("manifest.json"), options: .atomic)
        var sessions: [URLSession] = []; var clients: [ChatGPTPlanClient] = []
        defer { sessions.forEach { $0.invalidateAndCancel() } }
        for _ in candidates {
            let session = PlanHTTPTransport.makeSession(); sessions.append(session)
            let vault = store
            clients.append(ChatGPTPlanClient(session: session, tokenSupplier: { try await vault.accessToken() }, invalidateToken: { await vault.discardIfMatching($0) }))
        }
        ledger.reset()
        // The single production schedule is also checked by --self-check. These probes are
        // basic automated gates; all answers still require model-hidden human review.
        for (offset, job) in schedule.enumerated() {
            if offset == candidates.count {
                guard rows.allSatisfy({ $0.checks.values.allSatisfy { $0 } }) else { throw PlanError.service("vision_probe_quality_failed") }
            }
            let fixture = job.fixtureIndex == -1 ? suite.probe : suite.cases[job.fixtureIndex]
            try await request(fixture: fixture, model: candidates[job.modelIndex], client: clients[job.modelIndex], repetition: job.repetition, connection: job.connection, output: runRoot, owner: owner)
        }
        let completion: [String: Any] = ["completed_requests": rows.count, "recommendation": "pending_model_hidden_quality_review", "TTS": "not_run", "phone": "not_run", "next": "clear memory and attempt remote revocation before returning to idle"]
        try JSONSerialization.data(withJSONObject: completion, options: [.prettyPrinted, .sortedKeys]).write(to: runRoot.appendingPathComponent("completion.json"), options: .atomic)
        try lifecycle.ensureCurrent(owner)
        NSWorkspace.shared.open(runRoot)
    }
    private func request(fixture: BenchmarkFixture, model: BenchmarkModel, client: ChatGPTPlanClient, repetition: Int, connection: String, output: URL, owner: Int) async throws {
        try lifecycle.ensureCurrent(owner); guard rows.count < 39 else { throw PlanError.service("request_cap_reached") }
        let observations = BenchmarkObservations(); let index = rows.count + 1
        let callStarted = DispatchTime.now().uptimeNanoseconds
        label.stringValue = "本机测试 \(index)/39：\(model.slug) · \(fixture.id)。仅公开测试内容，遇到网络/额度错误立即停止。"
        let result: Result<String, Error>
        do {
            let answer = try await client.respond(model: model.slug, instructions: fixture.instructions, turns: fixture.turns, observer: { observations.append($0) })
            try lifecycle.ensureCurrent(owner)
            result = .success(answer)
        } catch { result = .failure(error) }
        let answer: String?, category: String?, outcome: String, checks: [String: Bool]
        switch result {
        case .success(let value): answer = value; category = nil; outcome = "success"; checks = BenchmarkSuite.checks(id: fixture.id, answer: value)
        case .failure(let error): answer = nil; category = benchmarkError(error); outcome = "failure"; checks = [:]
        }
        let row = BenchmarkRow(index: index, model: model.slug, fixture: fixture.id, repetition: repetition, connection: connection, outcome: outcome, errorCategory: category, answer: answer, checks: checks, callElapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - callStarted, observations: observations.snapshot())
        // Persistence errors are outside the network catch: append exactly once per request.
        try ledger.append(row) { values in try writeRows(values, output: output) }
        if case .failure(let error) = result { throw error }
    }
    private func writeRows(_ values: [BenchmarkRow], output: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: output.appendingPathComponent("results.json"), options: .atomic)
    }
    @objc private func cancel() {
        guard operation != nil || lifecycle.authenticated else { return }
        let owner = lifecycle.invalidate()
        operation?.cancel(); session?.cancel(); session = nil
        resetAccountControls(); cancelButton.isEnabled = false
        label.stringValue = "正在停止并清理本工具会话；取消可能已经消耗套餐额度，不自动重试。"
        operation = Task {
            let result = await lifecycle.finishCleanup(owner: owner)
            guard lifecycle.owns(owner), !terminating else { return }
            recordCleanup(result)
            label.stringValue = "已停止。" + benchmarkCleanupMessage(result)
            finishOperation(owner: owner)
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the only window must terminate, never leave a hidden benchmark running.
        NSApp.terminate(nil)
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        let owner = lifecycle.invalidate(closing: true)
        operation?.cancel(); operation = nil; session?.cancel(); session = nil
        resetAccountControls(); cancelButton.isEnabled = false
        label.stringValue = "正在清除本工具内存会话并尝试远端撤销；完成后退出。"
        Task {
            let result = await lifecycle.finishCleanup(owner: owner)
            recordCleanup(result)
            label.stringValue = benchmarkCleanupMessage(result)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

}

@main struct OpenVisionMacBenchmarkApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--lifecycle-check") {
            Task {
                do { try await BenchmarkLifecycleChecks.run(); exit(0) }
                catch { print("FAIL: local benchmark lifecycle checks"); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--self-check") {
            do {
                try BenchmarkSchedule.checkInvariants()
                let suite = try BenchmarkSuite.fixtures()
                precondition(suite.cases.count == 4)
                precondition(Set(suite.cases.map(\.id)).count == 4)
                for fixture in [suite.probe] + suite.cases {
                    precondition(fixture.turns.last?.text == fixture.prompt)
                    precondition(fixture.instructions == fixture.language.systemPrompt(for: fixture.prompt))
                    if let data = fixture.image {
                        guard let bitmap = NSBitmapImageRep(data: data) else { fatalError("Synthetic JPEG missing") }
                        precondition(bitmap.pixelsWide == 512 && bitmap.pixelsHigh == 512)
                    }
                }
                precondition(BenchmarkSuite.imageHash(suite.probe.image) != BenchmarkSuite.imageHash(suite.cases.last!.image))
                precondition(BenchmarkSuite.checks(id: "vision_probe_A", answer: "蓝色圆形，7。").values.allSatisfy { $0 })
                precondition(!BenchmarkSuite.checks(id: "vision_probe_A", answer: "红色三角形，4。").values.allSatisfy { $0 })
                precondition(benchmarkError(PlanError.service("private-server-message-must-not-leak")) == "service_failure_redacted")
                print("PASS: 4 public benchmark fixtures, distinct synthetic JPEG cards, production prompts, fact gates and error redaction. No login or model requests.")
            } catch { print("FAIL: benchmark fixture preparation"); exit(1) }
            return
        }
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let controller = BenchmarkController(); app.delegate = controller; app.run(); _ = controller
    }
}
