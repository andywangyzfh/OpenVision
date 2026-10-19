import Combine
import Foundation
import OpenVisionCore
import SubscriptionCore

@MainActor
final class ConversationViewModel: ObservableObject {
    @Published var language: ConversationLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "mvp.language"); stop()
            if !glasses.sdkAvailable && !preview { status = glassesSetupMessage }
        }
    }
    @Published var useGlassesMicrophone = true
    @Published var draft = ""
    @Published var messages: [ChatLine] = []
    @Published var status = ""
    @Published var modelID = ""
    @Published var models: [PlanModel] = []
    @Published private(set) var busy = false
    @Published private(set) var conversationActive = false
    @Published private(set) var signingIn = false
    @Published private(set) var authorizingSpeech = false
    @Published private(set) var stage: TurnLifecycle.Phase = .idle
    @Published var showAccount = false
    let account: ChatGPTAccountService
    let speech: SpeechService
    let glasses: GlassesPhotoService
    private let client: ChatGPTPlanClient
    private var lifecycle = TurnLifecycle()
    private var turnTask: Task<Void, Never>?
    private var history: [PlanTurn] = []
    private var activeForeground = true
    private let preview: Bool
    private var startGeneration = UUID()
    private var accountActionGeneration = UUID()
    private var accountObserver: AnyCancellable?

    init(account: ChatGPTAccountService, preview: Bool = false, sdkAvailable: Bool = false) {
        self.account = account
        self.preview = preview
        client = ChatGPTPlanClient(account: account)
        speech = SpeechService()
        glasses = GlassesPhotoService(monitoring: !preview, sdkAvailable: sdkAvailable)
        language = ConversationLanguage(rawValue: UserDefaults.standard.string(forKey: "mvp.language") ?? "") ?? .chinese
        speech.onUtterance = { [weak self] in self?.submit($0) }
        speech.onSpeechFinished = { [weak self] in
            guard let self, self.stage == .speaking else { return }
            self.busy = false
            self.lifecycle.stop(); self.stage = .idle
            if self.conversationActive { self.beginListening() }
        }
        speech.onFailure = { [weak self] in
            guard let self else { return }
            self.stop()
            self.status = self.text("收音已停止，请检查权限、连接后重试。", "Listening stopped. Check permissions and the connection, then retry.")
        }
        if preview { models = [.init(id: "fixture", name: "Local fixture (no network)")]; modelID = "fixture" }
        accountObserver = account.$isSignedIn.removeDuplicates().sink { [weak self] signedIn in
            Task { @MainActor [weak self] in
                guard let self, !self.preview, signedIn == self.account.isSignedIn else { return }
                if signedIn { await self.refreshModels() }
                else { self.stop(); self.models = []; self.modelID = "" }
            }
        }
        if !sdkAvailable && !preview { status = glassesSetupMessage }
    }

    var ready: Bool { preview || account.isSignedIn }
    var canSend: Bool { ready && !busy && !modelID.isEmpty }
    var debugPreview: Bool { preview }
    var glassesSetupMessage: String {
        text("眼镜功能未配置：Meta SDK 初始化失败。请配置真实 Meta 应用及 Apple 签名后重新启动。文字聊天与账号设置仍可使用。", "Glasses features are not configured: Meta SDK initialization failed. Configure a real Meta app and Apple signing, then relaunch. Text chat and account settings remain available.")
    }
    func text(_ chinese: String, _ english: String) -> String { language == .chinese ? chinese : english }

    func handleRegistrationURL(_ url: URL) async {
        guard url.scheme == "openvisionmvp" else { return }
        guard glasses.sdkAvailable else { status = glassesSetupMessage; return }
        do { try await glasses.handleRegistrationURL(url) }
        catch { status = text("眼镜注册回调失败，请重新连接。", "Glasses registration callback failed. Reconnect.") }
    }

    func connectAccount() async {
        guard !signingIn else { return }
        let generation = UUID(); accountActionGeneration = generation
        signingIn = true
        defer { if accountActionGeneration == generation { signingIn = false } }
        do { try await account.signIn() }
        catch {
            guard accountActionGeneration == generation else { return }
            status = failureMessage(error)
        }
    }

    func restoreAccount() async {
        guard !signingIn else { return }
        let generation = UUID(); accountActionGeneration = generation
        signingIn = true
        defer { if accountActionGeneration == generation { signingIn = false } }
        do { try await account.restoreSavedSession() }
        catch {
            guard accountActionGeneration == generation else { return }
            status = account.signOutNotice ?? text("未能恢复本机登录。可重新登录 ChatGPT；如有清理提示，请先重试清理。", "Saved sign-in could not be restored. Sign in to ChatGPT again; retry cleanup if a warning is shown.")
        }
    }

    func refreshModels() async {
        guard account.isSignedIn else { return }
        let generation = accountActionGeneration
        do {
            let available = try await client.models()
            guard account.isSignedIn, accountActionGeneration == generation else { return }
            models = available
            if !models.contains(where: { $0.id == modelID }) { modelID = models.first?.id ?? "" }
            status = models.isEmpty
                ? text("账号没有返回可用模型，请检查订阅授权。", "No models were returned. Check your plan authorization.")
                : text("已连接。可在 ChatGPT 设置核对本应用的用量与限额。", "Connected. Review this app's usage and limits in ChatGPT Settings.")
        } catch {
            guard account.isSignedIn, accountActionGeneration == generation else { return }
            status = failureMessage(error)
        }
    }

    func signOut() async {
        let generation = UUID(); accountActionGeneration = generation
        signingIn = false
        stop(); history.removeAll(); messages.removeAll()
        models = []; modelID = ""
        await account.signOut()
        guard accountActionGeneration == generation, !account.isSignedIn, !signingIn else { return }
        // Preserve the actual cleanup outcome. A failed deletion must never be
        // rewritten into a reassuring "local credentials removed" message.
        status = account.signOutNotice ?? text("已移除本机登录。可在 ChatGPT 设置中检查并撤销连接。", "Local sign-in removed. Review or revoke the connection in ChatGPT Settings.")
    }

    func retryLocalCleanup() async {
        let generation = UUID(); accountActionGeneration = generation
        stop()
        await account.retryLocalCleanup()
        guard accountActionGeneration == generation, !account.isSignedIn, !signingIn else { return }
        status = account.signOutNotice ?? text("本机登录已清除。", "Local sign-in removed.")
    }

    func toggleConversation() async {
        if conversationActive { stop(); return }
        guard !authorizingSpeech else { return }
        guard ready, !modelID.isEmpty else { showAccount = true; return }
        guard !preview else { status = text("这是本地界面测试模式，不连接麦克风。", "Local UI test mode does not open the microphone."); return }
        let generation = UUID()
        startGeneration = generation; authorizingSpeech = true
        let authorized = await speech.authorize()
        guard startGeneration == generation else { return }
        authorizingSpeech = false
        guard authorized else {
            status = text("需要麦克风和语音识别权限，请在 iPhone 设置中允许。", "Allow microphone and speech recognition in iPhone Settings.")
            return
        }
        guard activeForeground else { return }
        conversationActive = true
        beginListening()
    }

    private func beginListening() {
        guard conversationActive, activeForeground, !glasses.cameraActive else { return }
        do {
            try speech.listen(language: language, glassesMicrophone: useGlassesMicrophone)
            lifecycle.listen(); stage = .listening
            status = text("正在听，请说中文。", "Listening. Speak in English.")
        } catch {
            stop()
            if let speechError = error as? SpeechService.SpeechFailure,
               speechError == .bluetoothMicrophoneMissing || speechError == .ambiguousBluetoothInput {
                status = text("无法启用蓝牙麦克风。请连接眼镜、断开其他蓝牙耳机，或选择 iPhone 麦克风。", "Bluetooth microphone is unavailable. Connect glasses, disconnect other headsets, or select the iPhone microphone.")
            } else {
                status = text("无法启动此语言的语音识别。请检查语音识别权限、所选语言、网络和麦克风。", "Speech recognition could not start. Check speech permissions, the selected language, network and microphone.")
            }
        }
    }

    func sendDraft(photo: Bool = false) {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard photo || !value.isEmpty else { return }
        draft = ""
        if photo { run(question: value.isEmpty ? language.defaultPhotoQuestion : value, photo: true) }
        else { submit(value) }
    }

    func submit(_ text: String) {
        switch CommandParser().parse(text) {
        case .empty: if conversationActive { beginListening() }
        case .stop, .cancel: stop()
        case .photo(let question): run(question: question.isEmpty ? language.defaultPhotoQuestion : question, photo: true)
        case .conversation(let question): run(question: question, photo: false)
        }
    }

    private func run(question: String, photo: Bool) {
        guard !photo || glasses.sdkAvailable || preview else {
            stop(); status = glassesSetupMessage; return
        }
        guard activeForeground, canSend else {
            if !ready || modelID.isEmpty { showAccount = true }
            return
        }
        startGeneration = UUID(); authorizingSpeech = false
        speech.stopAll()
        let id = lifecycle.begin(photo: photo)
        stage = lifecycle.phase; busy = true
        messages.append(.init(user: true, text: question, photo: photo))
        let language = self.language
        let model = modelID
        status = photo ? text("正在按需拍照…", "Taking the requested photo…") : text("正在回答…", "Thinking…")
        turnTask = Task { [weak self] in
            guard let self else { return }
            do {
                let jpeg: Data?
                if photo {
                    // UI fixture deliberately cannot simulate a successful hardware photo.
                    if preview { throw GlassesPhotoService.PhotoFailure.noGlasses }
                    jpeg = try await glasses.captureJPEG()
                } else { jpeg = nil }
                try Task.checkCancellation()
                guard lifecycle.isCurrent(id) else { return }
                _ = lifecycle.advance(id, to: .answering); stage = .answering
                let turn = PlanTurn(role: "user", text: question, imageJPEG: jpeg)
                let answer: String
                if preview { answer = language == .chinese ? "本地测试回答。没有调用模型。" : "Local test reply. No model was called." }
                else { answer = try await client.respond(model: model, instructions: language.systemPrompt(for: question), turns: Array(history.suffix(12)) + [turn]) }
                try Task.checkCancellation()
                guard lifecycle.isCurrent(id), activeForeground else { return }
                messages.append(.init(user: false, text: answer, photo: false))
                // Photos live only in the current request. History contains bounded text, never JPEGs.
                history.append(.init(role: "user", text: String(question.prefix(6000)), imageJPEG: nil))
                history.append(.init(role: "assistant", text: String(answer.prefix(6000)), imageJPEG: nil))
                history = Array(history.suffix(12))
                if preview { busy = false; lifecycle.stop(); stage = .idle; return }
                _ = lifecycle.advance(id, to: .speaking); stage = .speaking
                status = text("正在播报…", "Speaking…")
                try speech.speak(answer, language: language.responseLanguage(for: question))
            } catch {
                guard lifecycle.isCurrent(id) else { return }
                busy = false; lifecycle.stop(); stage = .idle
                conversationActive = false
                if (error as? GlassesPhotoService.PhotoFailure) == .sdkUnavailable {
                    status = glassesSetupMessage
                } else if error is GlassesPhotoService.PhotoFailure {
                    status = self.text("未能取得新照片。请检查眼镜连接和相机授权，再点击重试；没有发送旧图。", "No fresh photo was obtained. Check the glasses and camera permission, then retry; no old photo was sent.")
                } else {
                    status = failureMessage(error)
                }
            }
        }
    }

    private func failureMessage(_ error: Error) -> String {
        if let speechError = error as? SpeechService.SpeechFailure, speechError == .voiceMissing {
            return text("没有可用的中文／英文播报声音。请在 iPhone 辅助功能的朗读内容设置中下载对应声音后重试。", "A matching speech voice is missing. Download the language voice in iPhone Accessibility speech settings, then retry.")
        }
        if let planError = error as? PlanError {
            switch planError {
            case .denied:
                return text("ChatGPT 登录已取消或被拒绝。可在设置中重新登录。", "ChatGPT sign-in was cancelled or declined. Try again in Settings.")
            case .missingPermission:
                return text("没有获得使用订阅额度的授权。请检查账号资格，并在重新登录时允许订阅用量。", "Plan usage was not authorized. Check account eligibility and grant plan usage when signing in again.")
            case .reauthenticationRequired:
                return text("订阅登录已失效，请在设置中重新登录 ChatGPT。", "Your plan sign-in expired or was revoked. Sign in again in Settings.")
            case .service(let code) where code == "http_429":
                return text("本次请求达到额度或频率限制，请稍后手动重试。没有转用付费 API。", "Plan usage or rate limit reached. Retry manually later. No paid API fallback.")
            case .service(let code) where code == "http_403":
                return text("账号没有此请求的权限，请检查订阅授权及模型资格。", "The account cannot use this request. Check plan authorization and model eligibility.")
            default: break
            }
        }
        return text("本轮未完成。检查网络、订阅授权和额度后重试；不会自动转用付费 API。", "This turn did not complete. Check network, plan authorization and limits; paid API fallback is disabled.")
    }

    func stop() {
        startGeneration = UUID(); authorizingSpeech = false
        conversationActive = false
        lifecycle.stop(); stage = .idle; busy = false
        turnTask?.cancel(); turnTask = nil
        speech.stopAll(); glasses.stop()
    }

    func clear() { stop(); messages.removeAll(); history.removeAll(); status = "" }
    func setForeground(_ active: Bool) {
        activeForeground = active
        if !active {
            accountActionGeneration = UUID(); signingIn = false
            stop(); account.cancelSignIn()
            status = text("已暂停。回到 App 后点击开始。", "Paused. Tap Start when you return.")
        }
    }
}

struct ChatLine: Identifiable {
    let id = UUID()
    let user: Bool
    let text: String
    let photo: Bool
}
