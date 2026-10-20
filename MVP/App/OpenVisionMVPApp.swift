import MWDATCore
import SwiftUI

@main
struct OpenVisionMVPApp: App {
    @StateObject private var account: ChatGPTAccountService
    @StateObject private var model: ConversationViewModel
    @StateObject private var glassesInputs: GlassesInputService
    @Environment(\.scenePhase) private var scenePhase
    private let voiceCoordinator: GlassesVoiceCoordinator
    private let preflightStatus: String?
    private let isMediaProbe: Bool
    #if DEBUG
    private let statusFixture: StatusUITestFixture?
    private var focusObserver: (@MainActor @Sendable (Bool) -> Void)? {
        guard let statusFixture else { return nil }
        return { focused in statusFixture.recordQuestionFocus(focused) }
    }
    #endif

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        isMediaProbe = arguments.contains("--mvp-media-probe")
        let preview = arguments.contains("--mvp-ui-testing")
        let platformStatusTesting = arguments.contains("--mvp-platform-status-testing")
        statusFixture = platformStatusTesting ? StatusUITestFixture(arguments: arguments) : nil
        let preflight = arguments.contains("--mvp-keychain-preflight")
        preflightStatus = preflight ? ProductionKeychainPreflight.run() : nil
        if preview || platformStatusTesting, arguments.contains("--reset-mvp-language") { UserDefaults.standard.set("zh-CN", forKey: "mvp.language") }
        if preview || platformStatusTesting, let index = arguments.firstIndex(of: "--mvp-test-language"), arguments.indices.contains(index + 1) {
            UserDefaults.standard.set(arguments[index + 1], forKey: "mvp.language")
        }
        #else
        let preview = false
        isMediaProbe = false
        let platformStatusTesting = false
        let preflight = false
        preflightStatus = nil
        #endif
        var sdkAvailable = false
        if !preview && !preflight && !platformStatusTesting && !isMediaProbe {
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
        #if DEBUG
        let injectedSpeech = statusFixture.map { SpeechService(driver: $0) }
        let model = ConversationViewModel(account: account, preview: preview || isMediaProbe, sdkAvailable: sdkAvailable, speechService: injectedSpeech)
        if let statusFixture { model.installLocalModelEffect(statusFixture.modelEffect()) }
        #else
        let model = ConversationViewModel(account: account, preview: preview, sdkAvailable: sdkAvailable)
        #endif
        let glassesInputs = GlassesInputService(sdkAvailable: sdkAvailable)
        voiceCoordinator = GlassesVoiceCoordinator(model: model, inputs: glassesInputs)
        _account = StateObject(wrappedValue: account)
        _model = StateObject(wrappedValue: model)
        _glassesInputs = StateObject(wrappedValue: glassesInputs)
    }

    var body: some Scene {
        WindowGroup {
            if isMediaProbe {
                #if DEBUG
                BluetoothMediaProbeView()
                #endif
            } else if let preflightStatus {
                Text(preflightStatus).padding().accessibilityIdentifier("diagnostics.keychain.preflight")
            } else {
                VStack(spacing: 0) {
                    MVPContentView(model: model, account: account, glasses: model.glasses, speech: model.speech)
                        .environmentObject(glassesInputs)
                        #if DEBUG
                        .environment(\.questionFocusObserver, focusObserver)
                        #endif
                        .frame(minHeight: 0, maxHeight: .infinity)
                    #if DEBUG
                    if let statusFixture {
                        StatusUITestControls(fixture: statusFixture, model: model)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    #endif
                }
                    .onOpenURL { url in
                        Task { await model.handleRegistrationURL(url) }
                    }
                    .onChange(of: scenePhase, initial: true) { _, phase in
                        voiceCoordinator.setActive(phase == .active, isBackground: phase == .background)
                    }
            }
        }
    }
}

#if DEBUG
private enum SDKStartupFailure: Error { case injected }
#endif
