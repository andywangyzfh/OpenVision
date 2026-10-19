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
                try await eventually("failed capture settled") { !vm.busy }
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
            let allScenarios = scenarios + additionalScenarios()
            for (name, scenario) in allScenarios {
                try await scenario()
                await drain()
                print("PASS: " + name)
            }
            print("PASS: \(allScenarios.count) production ConversationViewModel flow scenarios. Platform, account and model services are fakes; this does not validate iPhone or glasses hardware.")
        } catch {
            FileHandle.standardError.write(Data("FAIL: production VM flow acceptance: \(error)\n".utf8))
            restoreDefaults() // exit() does not unwind defer blocks.
            exit(1)
        }
    }
}
