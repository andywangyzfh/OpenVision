import MWDATCore
import SwiftUI

@main
struct OpenVisionMVPApp: App {
    @StateObject private var account: ChatGPTAccountService
    @StateObject private var model: ConversationViewModel
    private let preflightStatus: String?

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let preview = arguments.contains("--mvp-ui-testing")
        let preflight = arguments.contains("--mvp-keychain-preflight")
        preflightStatus = preflight ? ProductionKeychainPreflight.run() : nil
        if preview, arguments.contains("--reset-mvp-language") { UserDefaults.standard.set("zh-CN", forKey: "mvp.language") }
        if preview, let index = arguments.firstIndex(of: "--mvp-test-language"), arguments.indices.contains(index + 1) {
            UserDefaults.standard.set(arguments[index + 1], forKey: "mvp.language")
        }
        #else
        let preview = false
        let preflight = false
        preflightStatus = nil
        #endif
        var sdkAvailable = false
        if !preview && !preflight {
            do {
                #if DEBUG
                if arguments.contains("--mvp-force-sdk-setup-failure") { throw SDKStartupFailure.injected }
                #endif
                try Wearables.configure(); sdkAvailable = true
            } catch { /* Fail closed; never access Wearables.shared. */ }
        }
        // Every production cold start requires a person's explicit restore/sign-in action.
        // Preview and diagnostics also construct no active account or automatic Keychain load.
        let account = ChatGPTAccountService()
        let model = ConversationViewModel(account: account, preview: preview, sdkAvailable: sdkAvailable)
        _account = StateObject(wrappedValue: account)
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            if let preflightStatus {
                Text(preflightStatus).padding().accessibilityIdentifier("diagnostics.keychain.preflight")
            } else {
                MVPContentView(model: model, account: account, glasses: model.glasses, speech: model.speech)
                    .onOpenURL { url in
                        Task { await model.handleRegistrationURL(url) }
                    }
            }
        }
    }
}

#if DEBUG
private enum SDKStartupFailure: Error { case injected }
#endif
