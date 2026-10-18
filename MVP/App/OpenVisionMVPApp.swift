import MWDATCore
import SwiftUI

@main
struct OpenVisionMVPApp: App {
    @StateObject private var account: ChatGPTAccountService
    @StateObject private var model: ConversationViewModel

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let preview = arguments.contains("--mvp-ui-testing")
        let smoke = arguments.contains("--mvp-smoke-testing")
        if preview, arguments.contains("--reset-mvp-language") { UserDefaults.standard.set("zh-CN", forKey: "mvp.language") }
        if preview, let index = arguments.firstIndex(of: "--mvp-test-language"), arguments.indices.contains(index + 1) {
            UserDefaults.standard.set(arguments[index + 1], forKey: "mvp.language")
        }
        #else
        let preview = false
        let smoke = false
        #endif
        var setupFailed = false
        if !preview { do { try Wearables.configure() } catch { setupFailed = true } }
        let account = ChatGPTAccountService(restoreSession: !preview && !smoke)
        let model = ConversationViewModel(account: account, preview: preview)
        if setupFailed { model.status = "Meta SDK setup failed / Meta SDK 初始化失败" }
        _account = StateObject(wrappedValue: account)
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            MVPContentView(model: model, account: account, glasses: model.glasses, speech: model.speech)
                .onOpenURL { url in
                    guard url.scheme == "openvisionmvp" else { return }
                    Task {
                        do { _ = try await Wearables.shared.handleUrl(url) }
                        catch { model.status = model.text("眼镜注册回调失败，请重新连接。", "Glasses registration callback failed. Reconnect.") }
                    }
                }
        }
    }
}
