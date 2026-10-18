import OpenVisionCore
import SubscriptionCore
import SwiftUI

struct MVPContentView: View {
    @ObservedObject var model: ConversationViewModel
    @ObservedObject var account: ChatGPTAccountService
    @ObservedObject var glasses: GlassesPhotoService
    @ObservedObject var speech: SpeechService
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker(model.text("语言", "Language"), selection: $model.language) {
                    ForEach(ConversationLanguage.allCases) { Text($0.displayName).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("conversation.language")
                if model.debugPreview {
                    Text("LOCAL FIXTURE · NO NETWORK / 本地假数据模式").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Label(glasses.deviceCount > 0 ? model.text("眼镜已连接", "Glasses connected") : model.text("眼镜未连接", "Glasses disconnected"), systemImage: "eyeglasses")
                    Spacer()
                    Label(glasses.cameraActive ? model.text("相机开启", "Camera on") : model.text("相机关闭", "Camera off"), systemImage: "camera")
                        .foregroundStyle(glasses.cameraActive ? Color.orange : Color.secondary)
                        .accessibilityIdentifier("camera.status")
                }.font(.caption)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(model.messages) { line in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(line.user ? model.text("你", "You") : "OpenVision").font(.caption).foregroundStyle(.secondary)
                                    if line.photo { Label(model.text("本轮请求拍照", "Photo requested this turn"), systemImage: "camera").font(.caption) }
                                    Text(line.text).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading).id(line.id)
                            }
                        }.padding(.vertical)
                    }.onChange(of: model.messages.count) { _, _ in
                        if let id = model.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                if !speech.transcript.isEmpty && speech.isListening { Text(speech.transcript).font(.callout).foregroundStyle(.secondary) }
                if speech.isListening { Text(model.text("当前输入：", "Current input: ") + speech.inputName).font(.caption2).foregroundStyle(.secondary) }
                Text(model.status).font(.caption).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("conversation.status")
                HStack {
                    Button { Task { await model.toggleConversation() } } label: {
                        Label(model.conversationActive ? model.text("结束对话", "End conversation") : model.text("开始对话", "Start conversation"), systemImage: "mic")
                    }.buttonStyle(.borderedProminent).disabled(model.busy || model.authorizingSpeech).accessibilityIdentifier("conversation.start")
                    Button(model.text("停止", "Stop")) { model.stop() }.buttonStyle(.bordered).accessibilityIdentifier("conversation.stop")
                }
                HStack(alignment: .bottom) {
                    TextField(model.text("输入问题，或点击相机拍照提问", "Ask a question, or tap the camera to ask about a photo"), text: $model.draft, axis: .vertical)
                        .lineLimit(1...4).textFieldStyle(.roundedBorder).accessibilityIdentifier("conversation.input")
                    Button { model.sendDraft() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .disabled(!model.canSend || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel(model.text("发送", "Send")).accessibilityIdentifier("conversation.send")
                    Button { model.sendDraft(photo: true) } label: { Image(systemName: "camera.fill").font(.title2) }
                        .disabled(!model.canSend).accessibilityLabel(model.text("拍照问答", "Photo question")).accessibilityIdentifier("conversation.photo")
                }
                Text(model.text("照片仅用于本轮；会话不保存到磁盘。MVP 请保持 App 在前台。", "Photos are used for this turn only; chats are not saved to disk. Keep this MVP in the foreground."))
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding()
                .navigationTitle("OpenVision MVP")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button(model.text("清空", "Clear")) { model.clear() } }
                    ToolbarItem(placement: .topBarTrailing) { Button { model.showAccount = true } label: { Image(systemName: "gearshape") }.accessibilityIdentifier("settings.open") }
                }
                .sheet(isPresented: $model.showAccount) { settings }
                .onChange(of: model.showAccount) { _, presented in
                    if presented { model.stop() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.setForeground(false) }
                    else if phase == .active { model.setForeground(true) }
                }
        }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("ChatGPT") {
                    if account.isSignedIn {
                        Text(account.accountLabel)
                        Button(model.text("刷新模型", "Refresh models")) { Task { await model.refreshModels() } }
                        if !model.models.isEmpty {
                            Picker(model.text("模型", "Model"), selection: $model.modelID) { ForEach(model.models) { Text($0.name).tag($0.id) } }
                        }
                        Button(model.text("退出登录", "Sign out"), role: .destructive) { Task { await model.signOut() } }
                    } else {
                        Button("Continue with ChatGPT") { Task { await model.connectAccount() } }.disabled(model.signingIn)
                    }
                    Link(model.text("管理订阅用量及应用连接", "Manage plan usage and app connections"), destination: URL(string: "https://chatgpt.com/#settings/Usage")!)
                    Text(model.text("使用现有订阅额度；不会自动切换到付费 API。", "Uses your existing plan allowance. No automatic paid API fallback.")).font(.caption)
                }
                Section(model.text("眼镜", "Glasses")) {
                    Button(model.text("连接／注册眼镜", "Connect / register glasses")) { setup { try await glasses.register() } }
                    Button(model.text("安装／更新官方开发组件", "Install / update developer component")) { setup { try await glasses.installDeveloperComponent() } }
                    Button(model.text("授权眼镜相机", "Authorize glasses camera")) { setup {
                        let granted = try await glasses.authorizeCamera()
                        model.status = granted ? model.text("眼镜相机已授权。", "Glasses camera authorized.") : model.text("相机授权被拒绝，请在 Meta AI 中检查权限。", "Camera permission denied. Review permissions in Meta AI.")
                    } }
                    Text(model.text("这些操作会打开官方 Meta AI App。", "These actions open the official Meta AI app.")).font(.caption)
                }
                Section(model.text("语音", "Speech")) {
                    Toggle(model.text("使用蓝牙麦克风（请连接眼镜）", "Use Bluetooth microphone (connect glasses)"), isOn: $model.useGlassesMicrophone)
                        .onChange(of: model.useGlassesMicrophone) { _, _ in model.stop() }
                    Text(model.text("收音时会显示实际输入设备。请断开其他蓝牙耳机，以确认使用眼镜；关闭后使用 iPhone 麦克风。", "The actual input is shown while listening. Disconnect other Bluetooth headsets to verify glasses input. Turn off to use the iPhone microphone.")).font(.caption)
                }
                Section { Text(model.status).font(.caption) }
            }.navigationTitle(model.text("设置", "Settings"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(model.text("完成", "Done")) { model.showAccount = false } } }
        }
    }

    private func setup(_ action: @escaping @MainActor () async throws -> Void) {
        model.stop()
        Task {
            do { try await action() }
            catch { model.status = model.text("设置未完成，请检查 Meta AI 中的开发者模式和连接。", "Setup did not finish. Check Developer Mode and the connection in Meta AI.") }
        }
    }
}
