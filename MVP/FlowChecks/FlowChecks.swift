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
private func setup(signedIn: Bool = true) async throws -> (ConversationViewModel, FlowWorld) {
    FlowWorld.current = FlowWorld()
    let world = FlowWorld.current
    UserDefaults.standard.set(ConversationLanguage.chinese.rawValue, forKey: "mvp.language")
    let account = ChatGPTAccountService()
    let model = ConversationViewModel(account: account)
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
                world.responseError = .service("http_429"); send(vm, "请回答这个问题")
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
            for (name, scenario) in scenarios {
                try await scenario()
                await drain()
                print("PASS: " + name)
            }
            print("PASS: \(scenarios.count) production ConversationViewModel flow scenarios. Platform, account and model services are fakes; this does not validate iPhone or glasses hardware.")
        } catch {
            FileHandle.standardError.write(Data("FAIL: production VM flow acceptance: \(error)\n".utf8))
            restoreDefaults() // exit() does not unwind defer blocks.
            exit(1)
        }
    }
}
