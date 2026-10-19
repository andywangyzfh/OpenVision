import Darwin
import Foundation
import OpenVisionCore
import SubscriptionCore

private struct FlowFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw FlowFailure(message) }
}

@MainActor
private func eventually(_ message: String, _ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw FlowFailure("Timed out: " + message)
}

@MainActor
private func drain() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(3))
}

@MainActor
private func setup(signedIn: Bool = true, sdkAvailable: Bool = true) async throws -> (ConversationViewModel, FlowWorld) {
    FlowWorld.current = FlowWorld()
    let world = FlowWorld.current
    UserDefaults.standard.set(ConversationLanguage.chinese.rawValue, forKey: "mvp.language")
    let account = ChatGPTAccountService()
    let model = ConversationViewModel(account: account, sdkAvailable: sdkAvailable)
    await drain() // Allow the initial signed-out observation to settle before restore.
    if signedIn {
        account.restoreSignedIn()
        try await eventually("restored model catalog") { model.canSend }
    }
    return (model, world)
}

@MainActor
private func send(_ model: ConversationViewModel, _ value: String, photo: Bool = false) {
    model.draft = value; model.sendDraft(photo: photo)
    if photo, let request = model.pendingPhoto { model.confirmPhoto(requestID: request.id) }
}

@MainActor
private func finishTurn(_ model: ConversationViewModel) async throws {
    try await eventually("TTS started") { model.stage == .speaking }
    model.speech.finishPlayback()
    try await eventually("turn complete") { !model.busy }
}

@MainActor
private func additionalScenarios() -> [(String, @MainActor () async throws -> Void)] {
    var scenarios: [(String, @MainActor () async throws -> Void)] = [
        ("SDK initialization failure disables camera and callbacks while text account flow stays usable", {
            let (vm, world) = try await setup(sdkAvailable: false); defer { vm.stop() }
            try expect(!vm.glasses.sdkAvailable && vm.canSend, "SDK failure disabled usable account/text state")
            await vm.toggleConversation()
            vm.speech.emitUtterance("看看这个")
            if let pending = vm.pendingPhoto { vm.confirmPhoto(requestID: pending.id) }
            await drain()
            try expect(vm.status.contains("Meta SDK 初始化失败") && !vm.busy && !vm.conversationActive && !vm.speech.isListening, "SDK failure did not explain disabled photo or left voice session wedged")
            try expect(world.requests.isEmpty && vm.glasses.captures == 0 && vm.messages.isEmpty, "Unavailable SDK photo reached a service")
            await vm.handleRegistrationURL(URL(string: "openvisionmvp://registration?test=1")!)
            try expect(vm.glasses.registrationURLs == 0, "Unavailable SDK registration URL reached driver")
            vm.language = .english
            try expect(vm.status.contains("Meta SDK initialization failed") && vm.glassesSetupMessage.contains("Text chat and account settings remain available"), "English SDK guidance missing")
            send(vm, "Please answer without a photo"); try await finishTurn(vm)
            try expect(world.requests.count == 1 && vm.glasses.captures == 0, "SDK failure broke text-only flow")
            try expect(world.requests[0].turns.allSatisfy { $0.imageJPEG == nil }, "SDK failure used old image")
        }),
        ("configured SDK registration callback remains usable and unrelated URLs are ignored", {
            let (vm, _) = try await setup(); defer { vm.stop() }
            await vm.handleRegistrationURL(URL(string: "https://example.invalid/not-registration")!)
            try expect(vm.glasses.registrationURLs == 0, "Unrelated URL reached SDK")
            await vm.handleRegistrationURL(URL(string: "openvisionmvp://registration?test=1")!)
            try expect(vm.glasses.registrationURLs == 1, "Explicit available SDK was permanently disabled")
        }),
        ("short Mandarin speech turns reach the model unchanged", {
            let (vm, world) = try await setup(); defer { vm.stop() }
            await vm.toggleConversation()
            for (index, utterance) in ["好", "是", "继续"].enumerated() {
                vm.speech.emitUtterance(utterance)
                try await finishTurn(vm)
                try expect(world.requests.count == index + 1, "Short Mandarin was dropped or duplicated")
                try expect(world.requests.last?.turns.last?.text == utterance, "Short Mandarin changed")
                try expect(vm.glasses.captures == 0 && vm.speech.isListening, "Short text opened camera or lost listening")
            }
        }),
        ("empty and punctuation-only speech makes no model or camera request", {
            let (vm, world) = try await setup(); defer { vm.stop() }
            await vm.toggleConversation()
            for utterance in ["", "  \n ", "。！？", "..."] { vm.speech.emitUtterance(utterance) }
            await drain()
            try expect(world.requests.isEmpty && vm.glasses.captures == 0 && vm.messages.isEmpty, "Empty utterance reached a service")
            try expect(!vm.busy && vm.conversationActive && vm.speech.isListening, "Empty utterance wedged conversation")
        }),
        ("cancelled old reply cannot mutate a newer active turn", {
            let (vm, world) = try await setup(); defer { vm.stop() }
            world.holdResponses = true
            send(vm, "旧轮问题")
            try await eventually("old request suspended") { world.pendingResponses.count == 1 }
            vm.stop()
            send(vm, "新轮问题")
            try await eventually("new request suspended") { world.pendingResponses.count == 2 }
            world.resolveResponse(at: 0, answer: "迟到旧回答")
            await drain()
            try expect(vm.busy && vm.stage == .answering && vm.messages.count == 2, "Old completion reset or mutated newer turn")
            try expect(vm.speech.spoken.isEmpty && world.pendingResponses.count == 1, "Old completion escaped into audio")
            world.resolveResponse(at: 0, answer: "新轮回答")
            try await finishTurn(vm)
            try expect(vm.speech.spoken.count == 1 && vm.speech.spoken.last?.text == "新轮回答", "New turn did not complete independently")
            world.holdResponses = false
            send(vm, "后续问题"); try await finishTurn(vm)
            try expect(world.requests.last?.turns.contains(where: { $0.text == "迟到旧回答" || $0.text == "旧轮问题" }) == false, "Cancelled turn entered model history")
        }),
        ("signed-out submission stays idle then explicit sign-in and retry succeeds", {
            let (vm, world) = try await setup(signedIn: false); defer { vm.stop() }
            send(vm, "请回答这个问题")
            await drain()
            try expect(vm.showAccount && !vm.busy && world.requests.isEmpty && vm.glasses.captures == 0, "Signed-out request reached services")
            await vm.connectAccount()
            try await eventually("signed-in model ready") { vm.canSend }
            try expect(world.requests.isEmpty, "Signing in automatically retried inference")
            send(vm, "请回答这个问题"); try await finishTurn(vm)
            try expect(world.requests.count == 1 && vm.account.signInCalls == 1, "Explicit retry after sign-in failed")
        }),
        ("declined sign-in stays idle and explicit sign-in retry succeeds", {
            let (vm, world) = try await setup(signedIn: false); defer { vm.stop() }
            vm.account.signInError = .denied
            await vm.connectAccount(); await drain()
            try expect(!vm.signingIn && !vm.busy && !vm.ready && vm.models.isEmpty, "Declined sign-in left a busy or authenticated state")
            try expect(vm.status.contains("取消或被拒绝") && world.requests.isEmpty && vm.account.signInCalls == 1, "Sign-in error missing or retried")
            vm.account.signInError = nil
            await vm.connectAccount()
            try await eventually("retry sign-in ready") { vm.canSend }
            send(vm, "重新登录后回答"); try await finishTurn(vm)
            try expect(vm.account.signInCalls == 2 && world.requests.count == 1, "Explicit sign-in recovery failed")
        }),
        ("empty model catalog blocks requests and explicit catalog refresh recovers", {
            let (vm, world) = try await setup(signedIn: false); defer { vm.stop() }
            world.catalog = []
            vm.account.restoreSignedIn()
            try await eventually("empty catalog result") { world.modelLoads == 1 && vm.status.contains("没有返回可用模型") }
            send(vm, "没有模型时不能调用")
            await drain()
            try expect(!vm.busy && !vm.canSend && vm.models.isEmpty && world.requests.isEmpty, "Empty catalog allowed inference")
            try expect(world.modelLoads == 1, "Empty catalog automatically reloaded")
            world.catalog = [PlanModel(id: "recovered-model", name: "Recovered fixture")]
            await vm.refreshModels()
            send(vm, "模型恢复后回答"); try await finishTurn(vm)
            try expect(world.requests.count == 1 && world.requests.last?.model == "recovered-model", "Explicit catalog recovery failed")
        }),
        ("recognizer startup error returns idle and explicit restart recovers", {
            let (vm, world) = try await setup(); defer { vm.stop() }
            vm.speech.listenError = .unavailable
            await vm.toggleConversation()
            try expect(!vm.busy && !vm.conversationActive && !vm.speech.isListening && !vm.authorizingSpeech, "Recognizer failure left conversation busy")
            try expect(vm.status.contains("无法启动此语言") && world.requests.isEmpty && vm.speech.listenAttempts == 1, "Recognizer error missing or retried")
            vm.speech.listenError = nil
            await vm.toggleConversation()
            vm.speech.emitUtterance("恢复识别后回答"); try await finishTurn(vm)
            try expect(world.requests.count == 1 && vm.speech.isListening, "Explicit recognizer restart failed")
        }),
        ("recognition failure callback stops session and explicit restart recovers", {
            let (vm, world) = try await setup(); defer { vm.stop() }
            await vm.toggleConversation()
            vm.speech.emitFailure(); await drain()
            try expect(!vm.busy && !vm.conversationActive && !vm.speech.isListening, "ASR error callback did not stop conversation")
            try expect(vm.status.contains("收音已停止") && world.requests.isEmpty && vm.speech.listenAttempts == 1, "ASR error guidance or no-retry broken")
            await vm.toggleConversation()
            vm.speech.emitUtterance("再次开始识别"); try await finishTurn(vm)
            try expect(world.requests.count == 1 && vm.speech.isListening, "Explicit ASR recovery failed")
        }),
        ("missing TTS voice exits busy and explicit retry succeeds", {
            let (vm, world) = try await setup(); defer { vm.stop() }
            vm.speech.speakError = .voiceMissing
            send(vm, "请测试中文声音")
            try await eventually("missing voice settles") { world.requests.count == 1 && !vm.busy }
            await drain()
            try expect(vm.stage == .idle && !vm.conversationActive && vm.speech.spoken.isEmpty, "Missing voice left busy or spoke")
            try expect(vm.status.contains("播报声音") && vm.speech.speakAttempts == 1 && world.requests.count == 1, "Missing voice guidance or no-retry broken")
            vm.speech.speakError = nil
            send(vm, "下载声音后重试"); try await finishTurn(vm)
            try expect(world.requests.count == 2 && vm.speech.spoken.count == 1, "Explicit voice retry failed")
        })
    ]
    let photoCommands: [(String, ConversationLanguage)] = [
        ("看看这个", .chinese), ("拍照看看", .chinese), ("拍张照片告诉我这是什么", .chinese),
        ("Take a photo and tell me what this is", .english), ("What do you see?", .english)
    ]
    for (utterance, language) in photoCommands {
        scenarios.append(("LANG-04 explicit speech photo: " + utterance, {
            let (vm, world) = try await setup(); defer { vm.stop() }
            vm.language = language
            let fresh = Data(("fresh-" + utterance).utf8)
            vm.glasses.photos = [fresh]
            await vm.toggleConversation()
            vm.speech.emitUtterance(utterance)
            try expect(vm.pendingPhoto != nil && vm.glasses.captures == 0 && world.requests.isEmpty, "Photo intent opened camera before confirmation")
            if let pending = vm.pendingPhoto { vm.confirmPhoto(requestID: pending.id) }
            try await finishTurn(vm)
            try expect(vm.glasses.captures == 1 && world.requests.count == 1, "Explicit voice photo did not capture/send once")
            try expect(world.requests[0].turns.compactMap(\.imageJPEG) == [fresh], "Explicit voice photo did not carry current photo")
            try expect(vm.speech.spoken.count == 1 && vm.speech.isListening, "Photo answer did not resume conversation")
        }))
    }
    for utterance in ["我今天想聊摄影", "Let's talk about photography", "我昨天拍照了", "开始连续视频", "开始实时视频", "Start continuous video", "start a live video stream", "拍照并持续录像"] {
        scenarios.append(("no camera for discussion or continuous-video speech: " + utterance, {
            let (vm, world) = try await setup(); defer { vm.stop() }
            await vm.toggleConversation()
            vm.speech.emitUtterance(utterance)
            try await finishTurn(vm)
            try expect(vm.glasses.captures == 0 && !vm.glasses.cameraActive, "Non-photo utterance opened camera")
            try expect(world.requests.count == 1 && world.requests[0].turns.allSatisfy { $0.imageJPEG == nil }, "Non-photo turn carried visual data")
        }))
    }
    let modelFailures: [(String, any Error, String)] = [
        ("expired subscription", PlanError.reauthenticationRequired, "登录已失效"),
        ("revoked subscription", PlanError.reauthenticationRequired, "登录已失效"),
        ("403 permission", PlanError.service("http_403"), "没有此请求的权限"),
        ("500 server", PlanError.service("http_500"), "本轮未完成"),
        ("503 server", PlanError.service("http_503"), "本轮未完成"),
        ("offline network", URLError(.notConnectedToInternet), "本轮未完成"),
        ("network timeout", URLError(.timedOut), "本轮未完成"),
        ("empty model response", PlanError.service("empty_reply"), "本轮未完成")
    ]
    for (name, failure, guidance) in modelFailures {
        scenarios.append(("model failure leaves idle without retry, explicit retry succeeds: " + name, {
            let (vm, world) = try await setup(); defer { vm.stop() }
            world.responseError = failure
            send(vm, "请测试这一轮错误")
            try await eventually("failed turn settled") { world.requests.count == 1 && !vm.busy }
            await drain()
            try expect(vm.stage == .idle && !vm.conversationActive && vm.speech.spoken.isEmpty, "Failure left busy, listening or speaking")
            try expect(vm.status.contains(guidance) && vm.messages.allSatisfy(\.user), "Failure guidance missing or answer invented")
            try expect(world.requests.count == 1 && vm.glasses.captures == 0, "Failure automatically retried or captured")
            world.responseError = nil
            if (failure as? PlanError) == .reauthenticationRequired {
                // Recovery from a revoked/expired account is an explicit fresh sign-in, not
                // an implicit assumption that the same expired token became valid again.
                await vm.signOut(); await drain()
                await vm.connectAccount()
                try await eventually("explicit reauthentication ready") { vm.canSend }
                try expect(vm.account.signInCalls == 1 && world.requests.count == 1, "Reauthentication automatically retried inference")
            }
            send(vm, "现在手动重试"); try await finishTurn(vm)
            try expect(world.requests.count == 2 && vm.speech.spoken.count == 1, "Explicit retry after error failed")
        }))
    }
    for stop in ["停止", "取消", "Stop", "Cancel"] {
        scenarios.append(("explicit control cancels pending turn: " + stop, {
            let (vm, world) = try await setup(); defer { vm.stop() }
            world.holdResponses = true; send(vm, "等待中问题")
            try await eventually("request held") { world.pendingResponses.count == 1 }
            vm.submit(stop)
            world.resolveResponses(); await drain()
            try expect(!vm.busy && vm.stage == .idle && vm.speech.spoken.isEmpty, "Stop/Cancel failed to invalidate held answer")
            try expect(world.requests.count == 1 && vm.glasses.captures == 0, "Stop/Cancel created a request")
        }))
    }
    return scenarios
}

@MainActor
private func statusScenarios() -> [(String, @MainActor () async throws -> Void)] {
    var scenarios: [(String, @MainActor () async throws -> Void)] = []
    for language in ConversationLanguage.allCases {
        scenarios.append(("status: single typed turn finishes idle and can send again " + language.rawValue, {
            let (vm, world) = try await setup(); defer { vm.stop() }
            vm.language = language
            send(vm, language == .chinese ? "1加2等于多少" : "What is one plus two?")
            try await finishTurn(vm)
            let completion = language == .chinese ? "本轮已完成" : "Turn complete"
            try expect(vm.status.contains(completion), "Completion status remained stale: " + vm.status)
            try expect(!vm.busy && vm.stage == .idle && vm.canSend && !vm.conversationActive, "Finished typed turn did not return to actionable idle")
            try expect(vm.speech.listening.isEmpty, "Typed completion unexpectedly opened microphone")
            let stable = vm.status
            vm.speech.finishPlayback(); await drain()
            try expect(vm.status == stable && vm.stage == .idle, "Duplicate completion changed idle state")
            send(vm, language == .chinese ? "再回答一次" : "Answer once more")
            try await finishTurn(vm)
            try expect(world.requests.count == 2 && vm.canSend && vm.status.contains(completion), "The next typed turn could not complete")
        }))
        scenarios.append(("status: Stop cancels speaking and rejects late finish " + language.rawValue, {
            let (vm, world) = try await setup(); defer { vm.stop() }
            vm.language = language
            send(vm, language == .chinese ? "请回答这个问题" : "Please answer this question")
            try await eventually("speaking before Stop") { vm.stage == .speaking }
            vm.stop()
            let stopped = vm.status
            try expect(stopped.contains(language == .chinese ? "已停止" : "Stopped"), "Stop retained speaking text: " + stopped)
            try expect(vm.canSend && !vm.busy && vm.stage == .idle && !vm.conversationActive, "Stop left controls busy")
            vm.speech.finishPlayback(); await drain()
            try expect(vm.status == stopped && vm.stage == .idle && world.requests.count == 1, "Late finish overwrote stopped state")
        }))
        scenarios.append(("status: Stop cancels thinking and rejects late model " + language.rawValue, {
            let (vm, world) = try await setup(); defer { vm.stop() }
            vm.language = language; world.holdResponses = true
            send(vm, language == .chinese ? "等待中的问题" : "A pending question")
            try await eventually("pending model") { world.pendingResponses.count == 1 }
            vm.stop()
            let stopped = vm.status
            try expect(stopped.contains(language == .chinese ? "已停止" : "Stopped"), "Stop retained thinking text: " + stopped)
            world.resolveResponses(); await drain()
            try expect(vm.status == stopped && vm.stage == .idle && vm.canSend && vm.speech.spoken.isEmpty, "Late model changed stopped status")
        }))
        scenarios.append(("status: continuous speech completion resumes listening " + language.rawValue, {
            let (vm, world) = try await setup(); defer { vm.stop() }
            vm.language = language
            await vm.toggleConversation()
            vm.speech.emitUtterance(language == .chinese ? "1加2等于多少" : "What is one plus two?")
            try await finishTurn(vm)
            let listening = language == .chinese ? "正在听，请说中文。" : "Listening. Speak in English."
            try expect(vm.status == listening && vm.stage == .listening && vm.conversationActive && vm.speech.isListening, "Continuous turn failed to return to real listening state")
            try expect(!vm.busy && world.requests.count == 1 && vm.speech.listening.count == 2, "Continuous completion duplicated request/listen")
            vm.speech.finishPlayback(); await drain()
            try expect(vm.status == listening && vm.speech.listening.count == 2, "Late completion restarted listening twice")
        }))
    }
    scenarios.append(("status: completion and Stop preserve concrete account failure guidance", {
        let (vm, world) = try await setup(); defer { vm.stop() }
        send(vm, "请回答问题")
        try await eventually("speaking before account error") { vm.stage == .speaking }
        world.modelsError = .service("http_403")
        await vm.refreshModels()
        let failure = vm.status
        try expect(failure.contains("没有此请求的权限"), "Expected concrete permission guidance")
        vm.speech.finishPlayback(); await drain()
        try expect(vm.status == failure && vm.stage == .idle && !vm.busy, "Completion overwrote a concrete failure")
        vm.stop()
        try expect(vm.status == failure, "Stop overwrote concrete failure guidance")
    }))
    scenarios.append(("status: Stop preserves missing voice recovery guidance", {
        let (vm, world) = try await setup(); defer { vm.stop() }
        vm.speech.speakError = .voiceMissing
        send(vm, "请回答问题")
        try await eventually("missing voice settled") { world.requests.count == 1 && !vm.busy }
        let failure = vm.status
        try expect(failure.contains("播报声音"), "Missing voice guidance absent")
        vm.stop(); vm.speech.finishPlayback(); await drain()
        try expect(vm.status == failure && vm.stage == .idle, "Stop/late callback replaced missing voice guidance")
    }))
    for action in ["background", "clear", "sign-out"] {
        scenarios.append(("status: late playback preserves " + action + " guidance", {
            let (vm, _) = try await setup(); defer { vm.stop() }
            send(vm, "请回答问题")
            try await eventually("speaking before priority action") { vm.stage == .speaking }
            switch action {
            case "background": vm.setForeground(false)
            case "clear": vm.clear()
            default: await vm.signOut()
            }
            await drain()
            let priority = vm.status
            if action == "background" { try expect(priority.contains("已暂停"), "Pause guidance absent") }
            else if action == "clear" { try expect(priority.isEmpty && vm.messages.isEmpty, "Clear was not empty") }
            else { try expect(priority.contains("已移除本机登录"), "Sign-out guidance absent") }
            vm.speech.finishPlayback(); vm.stop(); await drain()
            try expect(vm.status == priority && vm.stage == .idle && !vm.busy, "Late finish/Stop replaced priority state")
        }))
    }
    return scenarios
}

@MainActor
private func photoSafetyScenarios() -> [(String, @MainActor () async throws -> Void)] {
    var result: [(String, @MainActor () async throws -> Void)] = []
    for action in ["cancel", "stop", "background", "clear", "language", "logout", "voice", "draft", "new-text", "new-photo"] {
        result.append(("photo safety: stale confirmation rejected after " + action, {
            let (vm, world) = try await setup(); defer { vm.stop() }
            vm.draft = "本次照片问题"; vm.sendDraft(photo: true)
            guard let pending = vm.pendingPhoto else { throw FlowFailure("Photo confirmation missing") }
            try expect(vm.glasses.captures == 0 && vm.glasses.mintedIntents == 0 && world.requests.isEmpty, "Request opened camera before confirmation")
            switch action {
            case "cancel": vm.cancelPhoto(requestID: pending.id)
            case "stop": vm.stop()
            case "background": vm.setForeground(false)
            case "clear": vm.clear()
            case "language": vm.language = .english
            case "logout": await vm.signOut()
            case "voice": await vm.handleGlassesVoiceToggle()
            case "draft": vm.draft = "新的草稿"
            case "new-text": world.holdResponses = true; vm.submit("这是新的普通文字问题")
            default: vm.submit("拍张照片告诉我这是什么")
            }
            await drain()
            let status = vm.status
            vm.confirmPhoto(requestID: pending.id); await drain()
            try expect(vm.glasses.captures == 0 && vm.glasses.mintedIntents == 0 && vm.status == status, "Old confirmation opened camera or changed newer status")
            if action == "new-photo" { try expect(vm.pendingPhoto?.id != nil && vm.pendingPhoto?.id != pending.id, "Old confirmation removed new pending request") }
            if action == "new-text" { world.resolveResponses(); try await finishTurn(vm) }
        }))
    }
    for utterance in ["看看这个", "看看这个，先别拍照", "look at this sentence", "What do you see?", "Take a photo and tell me what this is"] {
        result.append(("photo safety: speech request is confirmation-only " + utterance, {
            let (vm, world) = try await setup(); defer { vm.stop() }
            await vm.toggleConversation(); vm.speech.emitUtterance(utterance)
            await drain()
            try expect(vm.pendingPhoto != nil && vm.status.contains("尚未开启相机"), "Photo-like speech did not enter explicit confirmation")
            try expect(vm.glasses.captures == 0 && vm.glasses.mintedIntents == 0 && world.requests.isEmpty && !vm.glasses.cameraActive, "Speech opened camera before a separate App action")
            await vm.handleGlassesVoiceToggle()
            try expect(vm.pendingPhoto == nil && vm.speech.isListening && vm.glasses.captures == 0, "Voice activation confirmed a photo")
        }))
    }
    result.append(("photo safety: valid confirmation waits for inputs teardown and is one shot", {
        let (vm, world) = try await setup(); defer { vm.stop() }
        vm.glasses.photos = [Data("new-confirmed-photo".utf8)]
        var preparation: CheckedContinuation<Void, Error>?
        var hooks = 0
        vm.onConfirmedPhotoWillStart = { hooks += 1; try await withCheckedThrowingContinuation { preparation = $0 } }
        vm.draft = "请描述本张照片"; vm.sendDraft(photo: true)
        guard let request = vm.pendingPhoto else { throw FlowFailure("Pending request missing") }
        vm.confirmPhoto(requestID: request.id); vm.confirmPhoto(requestID: request.id)
        try await eventually("inputs teardown awaited") { preparation != nil }
        try expect(hooks == 1 && vm.glasses.mintedIntents == 0 && vm.glasses.captures == 0, "Confirmation started camera before inputs stopped")
        preparation?.resume(); preparation = nil
        try await finishTurn(vm)
        vm.confirmPhoto(requestID: request.id); await drain()
        try expect(vm.glasses.mintedIntents == 1 && vm.glasses.captures == 1 && world.requests.count == 1, "Confirmation replay captured more than one image")
        try expect(world.requests[0].turns.compactMap(\.imageJPEG) == [Data("new-confirmed-photo".utf8)], "Confirmed photo did not reach the model")
    }))
    result.append(("photo safety: cancellation during inputs teardown never mints an intent", {
        let (vm, world) = try await setup(); defer { vm.stop() }
        var preparation: CheckedContinuation<Void, Error>?
        vm.onConfirmedPhotoWillStart = { try await withCheckedThrowingContinuation { preparation = $0 } }
        vm.submit("看看这个")
        guard let request = vm.pendingPhoto else { throw FlowFailure("Pending request missing") }
        vm.confirmPhoto(requestID: request.id)
        try await eventually("preparation pending") { preparation != nil }
        await vm.handleGlassesVoiceToggle()
        preparation?.resume(); preparation = nil; await drain()
        try expect(vm.pendingPhoto == nil && vm.speech.isListening && vm.glasses.mintedIntents == 0 && vm.glasses.captures == 0 && world.requests.isEmpty, "Late inputs teardown opened camera after voice activation")
    }))
    result.append(("photo safety: failed inputs teardown never mints an intent", {
        let (vm, _) = try await setup(); defer { vm.stop() }
        vm.onConfirmedPhotoWillStart = { throw FlowFailure("Inputs teardown not confirmed") }
        vm.submit("看看这个")
        guard let request = vm.pendingPhoto else { throw FlowFailure("Pending request missing") }
        vm.confirmPhoto(requestID: request.id); await drain()
        try expect(vm.pendingPhoto == nil && vm.glasses.mintedIntents == 0 && vm.glasses.captures == 0 && vm.status.contains("相机尚未开启"), "Failed teardown did not fail closed")
    }))
    result.append(("photo safety: intent authorization failure leaves explicit retry guidance", {
        let (vm, world) = try await setup(); defer { vm.stop() }
        vm.glasses.intentAuthorizationFailure = FlowFailure("Previous capture still owns teardown")
        vm.submit("看看这个")
        guard let request = vm.pendingPhoto else { throw FlowFailure("Pending request missing") }
        vm.confirmPhoto(requestID: request.id); await drain()
        try expect(vm.pendingPhoto == nil && !vm.busy && vm.status.contains("未能准备本次拍照") && vm.glasses.mintedIntents == 0 && vm.glasses.captures == 0 && world.requests.isEmpty, "Intent mint failure silently dismissed confirmation or opened camera")
        vm.glasses.intentAuthorizationFailure = nil
        vm.glasses.photos = [Data("explicit-retry-photo".utf8)]
        vm.confirmPhoto(requestID: request.id); await drain()
        try expect(vm.glasses.captures == 0, "Failed request ID was reused without a new request")
        vm.submit("看看这个")
        guard let retry = vm.pendingPhoto else { throw FlowFailure("Retry confirmation missing") }
        vm.confirmPhoto(requestID: retry.id)
        try await finishTurn(vm)
        try expect(vm.glasses.captures == 1 && world.requests.count == 1, "Explicit retry failed after intent authorization recovered")
    }))
    result.append(("photo safety: voice toggle stops a busy typed turn without camera", {
        let (vm, world) = try await setup(); defer { vm.stop() }
        world.holdResponses = true; vm.submit("请回答这个普通问题")
        try await eventually("model pending") { world.pendingResponses.count == 1 }
        vm.showAccount = true
        vm.modelID = "" // Busy work must still stop even if a model is no longer selected.
        await vm.handleGlassesVoiceToggle(); world.resolveResponses(); await drain()
        try expect(!vm.busy && vm.speech.spoken.isEmpty && vm.glasses.captures == 0 && vm.pendingPhoto == nil, "Voice toggle failed to stop typed work safely")
    }))
    for missing in ["account", "model"] {
        result.append(("photo safety: unready voice gesture never requests microphone " + missing, {
            let (vm, world) = try await setup(signedIn: false); defer { vm.stop() }
            if missing == "model" {
                world.catalog = []; vm.account.restoreSignedIn()
                try await eventually("empty model catalog") { world.modelLoads == 1 }
            }
            await vm.handleGlassesVoiceToggle()
            try expect(vm.showAccount && vm.speech.authorizationRequests == 0 && vm.speech.listening.isEmpty && vm.glasses.captures == 0 && vm.glasses.mintedIntents == 0, "Unready gesture opened microphone or camera")
        }))
    }
    result.append(("photo safety: idle gesture in Settings never requests microphone", {
        let (vm, _) = try await setup(); defer { vm.stop() }
        vm.showAccount = true
        await vm.handleGlassesVoiceToggle()
        try expect(vm.speech.authorizationRequests == 0 && vm.speech.listening.isEmpty && vm.glasses.captures == 0 && vm.status.contains("关闭设置"), "Settings gesture opened microphone or camera")
    }))
    result.append(("photo safety: background gesture never requests microphone", {
        let (vm, _) = try await setup(); defer { vm.stop() }
        vm.setForeground(false)
        await vm.handleGlassesVoiceToggle()
        try expect(vm.speech.authorizationRequests == 0 && vm.speech.listening.isEmpty && vm.glasses.captures == 0, "Background gesture opened microphone or camera")
    }))
    result.append(("photo safety: invalid gesture permit cannot cancel a current photo request", {
        let (vm, _) = try await setup(); defer { vm.stop() }
        vm.submit("看看这个")
        let requestID = vm.pendingPhoto?.id
        await vm.handleGlassesVoiceToggle(ifAllowed: { false })
        try expect(requestID != nil && vm.pendingPhoto?.id == requestID && vm.speech.authorizationRequests == 0 && vm.speech.listening.isEmpty, "Stale gesture changed the current confirmation or opened microphone")
    }))
    result.append(("photo safety: revoked gesture permit after permission await never starts listening", {
        let (vm, _) = try await setup(); defer { vm.stop() }
        vm.speech.holdAuthorization = true
        var permitted = true
        let activation = Task { await vm.handleGlassesVoiceToggle(ifAllowed: { permitted }) }
        try await eventually("gesture permission awaiting") { vm.speech.pendingAuthorization != nil }
        permitted = false
        vm.speech.resolveAuthorization(true); await activation.value
        try expect(!vm.authorizingSpeech && !vm.conversationActive && vm.speech.listening.isEmpty && vm.glasses.captures == 0, "Revoked permit started microphone after permission returned")
    }))
    result.append(("photo safety: direct conversation entry rejects an invalid permit without side effects", {
        let (vm, _) = try await setup(); defer { vm.stop() }
        vm.submit("看看这个")
        let requestID = vm.pendingPhoto?.id
        await vm.toggleConversation(ifAllowed: { false })
        try expect(vm.pendingPhoto?.id == requestID && vm.speech.authorizationRequests == 0 && vm.speech.listening.isEmpty, "Conversation entry ignored permit before revoking photo or authorizing")
    }))
    result.append(("photo safety: accepted gesture invalidated by App Stop cannot restart microphone", {
        let (vm, _) = try await setup(); defer { vm.stop() }
        let acceptedGeneration = vm.voiceActivationGeneration
        vm.stop()
        await vm.handleGlassesVoiceToggle(expectedGeneration: acceptedGeneration)
        try expect(vm.speech.authorizationRequests == 0 && vm.speech.listening.isEmpty && !vm.conversationActive, "Queued gesture survived App Stop")
    }))
    result.append(("photo safety: accepted old gesture cannot cancel a newer photo or typed turn", {
        let (vm, world) = try await setup(); defer { vm.stop() }
        let acceptedGeneration = vm.voiceActivationGeneration
        vm.submit("看看这个")
        let requestID = vm.pendingPhoto?.id
        await vm.handleGlassesVoiceToggle(expectedGeneration: acceptedGeneration)
        try expect(requestID != nil && vm.pendingPhoto?.id == requestID && vm.speech.authorizationRequests == 0, "Queued gesture cancelled a newer photo")
        world.holdResponses = true; vm.submit("这是新的文字问题")
        try await eventually("new typed turn awaiting") { world.pendingResponses.count == 1 }
        await vm.handleGlassesVoiceToggle(expectedGeneration: acceptedGeneration)
        try expect(vm.busy && vm.speech.authorizationRequests == 0, "Old gesture stopped a newer turn")
        vm.stop(); world.resolveResponses(); await drain()
    }))
    result.append(("photo safety: current gesture generation completes authorization normally", {
        let (vm, _) = try await setup(); defer { vm.stop() }
        let acceptedGeneration = vm.voiceActivationGeneration
        await vm.handleGlassesVoiceToggle(expectedGeneration: acceptedGeneration)
        try expect(vm.speech.authorizationRequests == 1 && vm.speech.isListening && vm.conversationActive, "Own authorization generation was incorrectly compared with the old accepted generation")
    }))
    result.append(("photo safety: retained active camera does not claim a new request has not started", {
        let (vm, _) = try await setup(); defer { vm.stop() }
        vm.glasses.cameraActive = true
        vm.submit("看看这个")
        try expect(vm.pendingPhoto == nil && vm.glasses.mintedIntents == 0 && vm.status.contains("相机仍在关闭"), "Unconfirmed cleanup was described as camera not started")
    }))
    return result
}

@MainActor
private func authorizationLifecycleScenarios() -> [(String, @MainActor () async throws -> Void)] {
    [
        ("lifecycle: inactive account sheet preserves sign-in and completes after active", {
            let (vm, world) = try await setup(signedIn: false); defer { vm.stop() }
            vm.account.holdSignIn = true
            let signIn = Task { await vm.connectAccount() }
            try await eventually("account sheet waiting") { vm.account.pendingSignIns.count == 1 }
            vm.setForeground(false, cancelAccountAuthorization: false)
            try expect(vm.signingIn && vm.account.cancelledSignIns == 0 && !vm.account.isSignedIn, "Inactive authorization sheet cancelled a legitimate sign-in")
            vm.setForeground(true)
            vm.account.finishSignIn(at: 0); await signIn.value
            try await eventually("account sheet completed") { vm.canSend }
            try expect(vm.account.isSignedIn && !vm.signingIn && vm.account.cancelledSignIns == 0 && world.modelLoads == 1 && vm.speech.authorizationRequests == 0, "Sign-in did not complete normally after temporary inactivity")
        }),
        ("lifecycle: true background cancels inactive account sheet and rejects late completion", {
            let (vm, world) = try await setup(signedIn: false); defer { vm.stop() }
            vm.account.holdSignIn = true
            let signIn = Task { await vm.connectAccount() }
            try await eventually("account sheet waiting") { vm.account.pendingSignIns.count == 1 }
            vm.setForeground(false, cancelAccountAuthorization: false)
            vm.setForeground(false, cancelAccountAuthorization: true)
            try expect(!vm.signingIn && vm.account.cancelledSignIns == 1, "Background failed to cancel account authorization")
            vm.setForeground(true)
            vm.account.finishSignIn(at: 0); await signIn.value; await drain()
            try expect(!vm.account.isSignedIn && !vm.ready && world.modelLoads == 0 && vm.models.isEmpty && vm.speech.authorizationRequests == 0, "Late cancelled credentials reactivated the account")
        }),
        ("lifecycle: inactive still revokes pending speech permission without cancelling account", {
            let (vm, _) = try await setup(); defer { vm.stop() }
            vm.speech.holdAuthorization = true
            let activation = Task { await vm.toggleConversation() }
            try await eventually("microphone permission waiting") { vm.speech.pendingAuthorization != nil }
            vm.setForeground(false, cancelAccountAuthorization: false)
            vm.speech.resolveAuthorization(true); await activation.value
            try expect(!vm.authorizingSpeech && !vm.conversationActive && vm.speech.listening.isEmpty && vm.account.cancelledSignIns == 0, "Inactive account preservation also preserved microphone activation")
        }),
        ("lifecycle: inactive still revokes photo confirmation without cancelling account", {
            let (vm, world) = try await setup(); defer { vm.stop() }
            vm.submit("看看这个")
            guard let request = vm.pendingPhoto else { throw FlowFailure("Photo confirmation missing") }
            vm.setForeground(false, cancelAccountAuthorization: false)
            vm.setForeground(true)
            vm.confirmPhoto(requestID: request.id); await drain()
            try expect(vm.pendingPhoto == nil && vm.glasses.mintedIntents == 0 && vm.glasses.captures == 0 && world.requests.isEmpty && vm.account.cancelledSignIns == 0, "Inactive preserved a camera authorization while preserving account sheet")
        })
    ]
}

@main
struct FlowChecks {
    @MainActor
    static func main() async {
        let originalLanguage = UserDefaults.standard.object(forKey: "mvp.language")
        let restoreDefaults = {
            if let originalLanguage { UserDefaults.standard.set(originalLanguage, forKey: "mvp.language") }
            else { UserDefaults.standard.removeObject(forKey: "mvp.language") }
        }
        defer { restoreDefaults() }
        let scenarios: [(String, @MainActor () async throws -> Void)] = [
            ("reauthentication notification stops a pending turn and preserves its visible reason", {
                let (vm, world) = try await setup(); defer { vm.stop() }
                world.holdResponses = true; send(vm, "请回答这个问题")
                try await eventually("request waiting before invalidation") { world.pendingResponses.count == 1 }
                vm.account.invalidate(); await drain()
                try expect(!vm.ready && !vm.busy && vm.status.contains("已失效"), "Account invalidation hid its reason behind the old thinking status")
                let reason = vm.status
                world.resolveResponses(); await drain()
                try expect(vm.status == reason && vm.speech.spoken.isEmpty, "Old response replaced the reauthentication reason or spoke")
            }),
            ("current model failure remains visible when account invalidation arrives first", {
                let (vm, world) = try await setup(); defer { vm.stop() }
                world.modelsError = .reauthenticationRequired
                world.invalidateBeforeModelsError = true
                await vm.refreshModels(); await drain()
                try expect(!vm.ready && vm.models.isEmpty && vm.status.contains("已失效"), "Invalidation hid the current expired-login error")
            }),
            ("background cancels sign-in UI and an old completion cannot clear a new attempt", {
                let (vm, _) = try await setup(); defer { vm.stop() }
                await vm.signOut(); await drain()
                vm.account.holdSignIn = true
                let oldAttempt = Task { await vm.connectAccount() }
                try await eventually("first sign-in waiting") { vm.account.pendingSignIns.count == 1 }
                vm.setForeground(false); vm.setForeground(true)
                try expect(!vm.signingIn && !vm.ready, "Background left the old sign-in UI locked")
                let newAttempt = Task { await vm.connectAccount() }
                try await eventually("new sign-in waiting") { vm.account.pendingSignIns.count == 2 }
                vm.account.finishSignIn(at: 0); await oldAttempt.value
                try expect(vm.signingIn && !vm.ready, "Old sign-in completion cleared the current attempt")
                vm.account.finishSignIn(at: 0); await newAttempt.value; await drain()
                try expect(!vm.signingIn && vm.ready && !vm.models.isEmpty, "Explicit new sign-in could not recover")
            }),
            ("late sign-out cannot overwrite the newly connected account status", {
                let (vm, _) = try await setup(); defer { vm.stop() }
                vm.account.holdSignOut = true
                let oldSignOut = Task { await vm.signOut() }
                try await eventually("sign-out waiting for remote result") { vm.account.pendingSignOut != nil }
                await vm.connectAccount(); await drain()
                let connectedStatus = vm.status
                try expect(vm.account.isSignedIn && !vm.models.isEmpty, "New account did not connect")
                vm.account.finishSignOut(); await oldSignOut.value; await drain()
                try expect(vm.status == connectedStatus && vm.account.isSignedIn, "Old sign-out overwrote the new account status")
            }),
            ("late cleanup retry cannot overwrite the newly connected account status", {
                let (vm, _) = try await setup(); defer { vm.stop() }
                await vm.signOut(); await drain()
                vm.account.holdCleanupRetry = true
                let oldCleanup = Task { await vm.retryLocalCleanup() }
                try await eventually("cleanup waiting for storage") { vm.account.pendingCleanup != nil }
                await vm.connectAccount(); await drain()
                let connectedStatus = vm.status
                vm.account.finishCleanup(); await oldCleanup.value; await drain()
                try expect(vm.status == connectedStatus && vm.account.isSignedIn, "Old cleanup overwrote the new account status")
            }),
            ("sign-out preserves unsafe cleanup notice instead of claiming credentials were removed", {
                for language in ConversationLanguage.allCases {
                    let (vm, _) = try await setup(); defer { vm.stop() }
                    vm.language = language
                    let notice = "未能确认本机凭据清理；请重试。 / Local credential cleanup was not confirmed; retry."
                    vm.account.signOutNotice = notice
                    await vm.signOut(); await drain()
                    try expect(vm.status == notice && !vm.ready && vm.messages.isEmpty && vm.models.isEmpty,
                               "The actual failed-cleanup warning was replaced by a successful-removal claim")
                }
            }),
            ("restored account loads its model catalog", {
                let (vm, world) = try await setup(signedIn: false)
                defer { vm.stop() }
                try expect(vm.models.isEmpty && !vm.ready, "Signed-out state should not load models")
                vm.account.restoreSignedIn()
                try await eventually("restored model selection") { vm.modelID == "fixture-plan" }
                try expect(world.modelLoads == 1 && vm.models == world.catalog, "Restoration must trigger exactly one catalog load")
            }),
            ("Chinese typed turn uses Chinese prompt and speech", {
                let (vm, world) = try await setup(); defer { vm.stop() }
                send(vm, "请帮我安排今天的任务")
                try await finishTurn(vm)
                try expect(world.requests.count == 1, "One typed turn must produce one request")
                try expect(world.requests[0].instructions.contains("简体中文"), "Chinese prompt missing")
                try expect(world.requests[0].turns.last?.text == "请帮我安排今天的任务", "Question changed")
                try expect(world.requests[0].turns.allSatisfy { $0.imageJPEG == nil }, "Text-only request contained a photo")
                try expect(vm.speech.spoken.last?.language == .chinese && vm.messages.count == 2, "Chinese reply was not spoken/displayed")
            }),
            ("English typed turn uses English prompt and speech", {
                let (vm, world) = try await setup(); defer { vm.stop() }
                vm.language = .english; world.answer = "This is the offline English answer."
                send(vm, "Please help me plan my day")
                try await finishTurn(vm)
                try expect(world.requests[0].instructions.contains("Answer naturally in English"), "English prompt missing")
                try expect(vm.speech.spoken.last?.language == .english && vm.messages.last?.text == world.answer, "English reply mismatch")
            }),
            ("each photo is fresh and later text carries no old image", {
                let (vm, world) = try await setup(); defer { vm.stop() }
                let photoA = Data("fixture-photo-A".utf8), photoB = Data("fixture-photo-B".utf8)
                vm.glasses.photos = [photoA, photoB]
                send(vm, "第一张是什么", photo: true); try await finishTurn(vm)
                send(vm, "第二张是什么", photo: true); try await finishTurn(vm)
                send(vm, "请总结一下刚才的回答"); try await finishTurn(vm)
                try expect(world.requests.count == 3 && vm.glasses.captures == 2, "Photo/text call counts mismatch")
                try expect(world.requests[0].turns.compactMap(\.imageJPEG) == [photoA], "First request did not contain exactly photo A")
                try expect(world.requests[1].turns.compactMap(\.imageJPEG) == [photoB], "Second request reused an old photo")
                try expect(world.requests[2].turns.allSatisfy { $0.imageJPEG == nil }, "Text round retained an old image")
            }),
            ("photo failure never calls model or speaks", {
                let (vm, world) = try await setup(); defer { vm.stop() }
                vm.glasses.failCapture = true
                send(vm, "这是什么", photo: true)
                try await eventually("failed capture settled") { vm.glasses.captures == 1 && !vm.busy }
                try expect(vm.glasses.captures == 1 && world.requests.isEmpty, "Failed capture reached model")
                try expect(vm.messages.allSatisfy(\.user) && vm.speech.spoken.isEmpty, "Failed capture invented an answer")
                try expect(vm.status.contains("没有发送旧图"), "Fresh-photo failure message missing")
            }),
            ("Stop discards a noncooperative late model result", {
                let (vm, world) = try await setup(); defer { vm.stop() }
                world.holdResponses = true; send(vm, "请回答这个问题")
                try await eventually("request suspended") { world.pendingResponses.count == 1 }
                vm.stop(); let messages = vm.messages.count
                world.resolveResponses(); await drain()
                try expect(vm.messages.count == messages && vm.speech.spoken.isEmpty && !vm.busy, "Stopped result mutated UI or speech")
            }),
            ("backgrounding discards late reply and cancels sign-in", {
                let (vm, world) = try await setup(); defer { vm.stop() }
                world.holdResponses = true; send(vm, "请回答这个问题")
                try await eventually("request suspended") { world.pendingResponses.count == 1 }
                vm.setForeground(false); let messages = vm.messages.count
                world.resolveResponses(); await drain()
                try expect(vm.messages.count == messages && vm.speech.spoken.isEmpty, "Background result reached output")
                try expect(!vm.speech.isListening && !vm.conversationActive && vm.account.cancelledSignIns == 1, "Background did not stop session")
                vm.setForeground(true)
                try expect(!vm.conversationActive && !vm.speech.isListening, "Foreground auto-restarted microphone")
            }),
            ("language change cancels a pending reply", {
                let (vm, world) = try await setup(); defer { vm.stop() }
                world.holdResponses = true; send(vm, "请回答这个问题")
                try await eventually("request suspended") { world.pendingResponses.count == 1 }
                vm.language = .english; let messages = vm.messages.count
                world.resolveResponses(); await drain()
                try expect(vm.language == .english && vm.messages.count == messages && vm.speech.spoken.isEmpty, "Old-language reply escaped cancellation")
            }),
            ("Stop while permission is pending cannot open microphone later", {
                let (vm, _) = try await setup(); defer { vm.stop() }
                vm.speech.holdAuthorization = true
                let start = Task { await vm.toggleConversation() }
                try await eventually("permission pending") { vm.speech.pendingAuthorization != nil }
                vm.stop(); vm.speech.resolveAuthorization(true); await start.value
                try expect(vm.speech.listening.isEmpty && !vm.conversationActive && !vm.authorizingSpeech, "Late permission opened microphone after Stop")
            }),
            ("typed request supersedes pending microphone permission", {
                let (vm, world) = try await setup(); defer { vm.stop() }
                vm.speech.holdAuthorization = true; world.holdResponses = true
                let start = Task { await vm.toggleConversation() }
                try await eventually("permission pending") { vm.speech.pendingAuthorization != nil }
                send(vm, "先回答这个文字问题")
                try await eventually("typed request suspended") { world.pendingResponses.count == 1 }
                vm.speech.resolveAuthorization(true); await start.value
                try expect(vm.speech.listening.isEmpty && !vm.conversationActive, "Late permission opened microphone during typed request")
                world.resolveResponses(); try await finishTurn(vm)
                try expect(vm.speech.listening.isEmpty, "Typed TTS unexpectedly started microphone")
            }),
            ("rapid duplicate submissions send only once", {
                let (vm, world) = try await setup(); defer { vm.stop() }
                world.holdResponses = true
                vm.submit("请回答一次"); vm.submit("请回答一次"); vm.submit("请回答一次")
                try await eventually("one request suspended") { world.pendingResponses.count == 1 }
                try expect(world.requests.count == 1 && vm.messages.count == 1, "Duplicate taps created extra request or message")
                world.resolveResponses(); try await finishTurn(vm)
            }),
            ("TTS completion resumes an active conversation only", {
                let (vm, world) = try await setup(); defer { vm.stop() }
                await vm.toggleConversation()
                try expect(vm.speech.listening.count == 1 && vm.conversationActive, "Conversation did not begin listening")
                vm.speech.emitUtterance("请回答这个问题")
                try await eventually("speaking") { vm.stage == .speaking }
                try expect(world.requests.count == 1 && !vm.speech.isListening, "Recognition was not stopped during reply")
                vm.speech.finishPlayback()
                try expect(vm.speech.listening.count == 2 && vm.stage == .listening, "TTS did not restore listening")
                vm.stop(); vm.speech.finishPlayback()
                try expect(vm.speech.listening.count == 2 && !vm.conversationActive, "Late TTS callback restarted stopped conversation")
            }),
            ("Stop while capture is pending discards the late photo", {
                let (vm, world) = try await setup(); defer { vm.stop() }
                vm.glasses.holdCapture = true; send(vm, "请看看这张图", photo: true)
                try await eventually("capture suspended") { vm.glasses.pendingCapture != nil }
                vm.stop(); vm.glasses.resolveCapture(Data("late-photo".utf8)); await drain()
                try expect(world.requests.isEmpty && vm.speech.spoken.isEmpty && !vm.busy, "Cancelled photo reached model or output")
            }),
            ("model quota error produces no invented answer or retry", {
                let (vm, world) = try await setup(); defer { vm.stop() }
                world.responseError = PlanError.service("http_429"); send(vm, "请回答这个问题")
                try await eventually("model error settled") { !vm.busy }
                try expect(world.requests.count == 1 && vm.speech.spoken.isEmpty && vm.messages.allSatisfy(\.user), "Model error retried or produced output")
                try expect(vm.status.contains("没有转用付费 API"), "Quota recovery message missing")
            }),
            ("sign-out discards pending response and clears history", {
                let (vm, world) = try await setup(); defer { vm.stop() }
                world.holdResponses = true; send(vm, "请回答这个问题")
                try await eventually("request suspended") { world.pendingResponses.count == 1 }
                await vm.signOut(); world.resolveResponses(); await drain()
                try expect(!vm.ready && vm.models.isEmpty && vm.messages.isEmpty && vm.speech.spoken.isEmpty, "Signed-out request restored output or account")
            }),
            ("denied speech permission leaves conversation idle", {
                let (vm, _) = try await setup(); defer { vm.stop() }
                vm.speech.authorizationAllowed = false
                await vm.toggleConversation()
                try expect(vm.speech.listening.isEmpty && !vm.conversationActive && !vm.authorizingSpeech, "Denied permission activated conversation")
                try expect(vm.status.contains("需要麦克风"), "Permission guidance missing")
            }),
            ("language choice survives reconstruction of production VM", {
                let (vm, _) = try await setup(); defer { vm.stop() }
                vm.language = .english
                let recreated = ConversationViewModel(account: vm.account)
                defer { recreated.stop() }
                try expect(recreated.language == .english, "Persisted language was not restored")
                recreated.language = .chinese
                let recreatedAgain = ConversationViewModel(account: vm.account)
                defer { recreatedAgain.stop() }
                try expect(recreatedAgain.language == .chinese, "Chinese selection was not persisted")
            })
        ]
        do {
            let allScenarios = scenarios + additionalScenarios() + statusScenarios() + photoSafetyScenarios() + authorizationLifecycleScenarios()
            let filter = ProcessInfo.processInfo.environment["OPENVISION_FLOW_FILTER"]
            let selected = filter.map { needle in allScenarios.filter { $0.0.contains(needle) } } ?? allScenarios
            try expect(!selected.isEmpty, "No scenarios matched the requested filter")
            for (name, scenario) in selected {
                try await scenario()
                await drain()
                print("PASS: " + name)
            }
            print("PASS: \(selected.count) production ConversationViewModel flow scenarios. Platform, account and model services are fakes; this does not validate iPhone or glasses hardware.")
        } catch {
            FileHandle.standardError.write(Data("FAIL: production VM flow acceptance: \(error)\n".utf8))
            restoreDefaults() // exit() does not unwind defer blocks.
            exit(1)
        }
    }
}
