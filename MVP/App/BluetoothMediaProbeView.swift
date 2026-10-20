#if DEBUG
import OpenVisionCore
import SwiftUI

/// An isolated hardware probe, selected only by a DEBUG launch argument. No camera,
/// account restore, microphone or model action is reachable from this screen.
struct BluetoothMediaProbeView: View {
    @StateObject private var service: BluetoothMediaTriggerService
    @StateObject private var recorder: MediaProbeRecorder
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let service = BluetoothMediaTriggerService()
        let recorder = MediaProbeRecorder()
        service.onDiagnosticEvent = { [weak service, weak recorder] command, uptime, foreground in
            guard let service, let recorder else { return }
            recorder.record("media_event", service: service, scene: foreground ? "active" : "inactive_or_background",
                            uptime: uptime, command: command.rawValue)
        }
        _service = StateObject(wrappedValue: service)
        _recorder = StateObject(wrappedValue: recorder)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("锁屏触控测试 · 仅测试按键") {
                    Text("本页不收音、不拍照、不调用 GPT。开启待命会持续播放无声音频，并占用媒体控制；测试结束请停止。")
                    Text("先将 iPhone 的音频输出选择为眼镜，暂停其他音乐。开启成功会响一声；每收到一个媒体事件再响一声。")
                    Button("开启按键测试") {
                        service.setEnabled(true)
                        Task { await service.arm(); record("arm_finished") }
                    }
                    .disabled(service.isArmed || service.isArming || service.isCleaningUp)
                    .accessibilityIdentifier("media-probe.arm")
                    Button("停止按键测试", role: .destructive) {
                        service.setEnabled(false)
                        Task { _ = await service.disarmAndWait(); record("stopped") }
                    }
                    .accessibilityIdentifier("media-probe.stop")
                    Text(service.isArmed ? "正在待命：可以锁屏，然后轻触镜腿" : "未待命")
                        .accessibilityIdentifier("media-probe.status")
                    if let failure = service.failure { Text(failureText(failure)).foregroundStyle(.orange) }
                    if let exportError = recorder.exportError { Text(exportError).foregroundStyle(.orange) }
                    Button("重新导出测试记录") { record("manual_export") }
                        .accessibilityIdentifier("media-probe.export")
                }
                Section("收到的原始事件") {
                    ForEach(MediaVoiceCommand.allCases, id: \.self) { command in
                        LabeledContent(command.rawValue, value: String(service.eventCounts[command, default: 0]))
                            .accessibilityIdentifier("media-probe.count.\(command.rawValue)")
                    }
                    Text("一次手势可能产生多个事件；本页记录原始数量，不据此宣称已经能启动对话。控制中心和其他蓝牙遥控也可能产生这些事件。")
                        .font(.caption)
                }
                Section("测试顺序") {
                    Text("1. 开启后轻触一次镜腿，查看计数。\n2. 锁屏等待 30 秒，再轻触一次。\n3. 解锁查看计数；记录是否听到提示音。\n4. 测试结束点击停止。不要按实体拍摄键。")
                    Text("请同时观察眼镜相机指示灯，应始终不亮。若亮起，立即停止并报告。")
                }
            }
            .navigationTitle("OpenVision 触控诊断")
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            service.setForeground(phase == .active)
            record("scene_\(String(describing: phase))")
        }
        .onChange(of: service.failure) { _, _ in record("failure") }
        .onDisappear { service.setEnabled(false) }
    }

    private func record(_ event: String) {
        recorder.record(event, service: service, scene: String(describing: scenePhase))
    }

    private func failureText(_ failure: BluetoothMediaFailure) -> String {
        switch failure {
        case .bluetoothUnavailable, .routeLost: "请连接眼镜，并在控制中心将音频输出选为眼镜，然后重新开启。"
        case .otherAudioPlaying: "请暂停其他音乐或音频后重新开启。"
        case .interrupted: "音频被其他应用或通话打断。请结束后手动重新开启。"
        case .notForeground: "请在此页面重新开启测试。"
        default: "待命未能保持（\(String(describing: failure))）。请记录此提示，停止后重试。"
        }
    }
}

@MainActor
private final class MediaProbeRecorder: ObservableObject {
    @Published private(set) var exportError: String?
    private let sessionID = UUID().uuidString
    private var observations: [[String: String]] = []
    private var sequence = 0

    func record(_ event: String, service: BluetoothMediaTriggerService, scene: String,
                uptime: UInt64? = nil, command: String? = nil) {
        sequence += 1
        observations.append([
            "sequence": String(sequence), "event": event,
            "time": ISO8601DateFormatter().string(from: Date()),
            "receiptUptimeNanoseconds": uptime.map(String.init) ?? "not_a_media_receipt",
            "sceneAtReceipt": scene, "armed": String(service.isArmed),
            "command": command ?? "none",
            "failure": service.failure.map { String(describing: $0) } ?? "none"
        ])
        if observations.count > 200 { observations.removeFirst(observations.count - 200) }
        let payload: [String: Any] = [
            "sessionID": sessionID, "kind": "media-event-probe-only",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "counts": Dictionary(uniqueKeysWithValues: service.eventCounts.map { ($0.key.rawValue, $0.value) }),
            "observations": observations,
            "scope": "event receipts only; camera/microphone/model safety is source-reviewed, not dynamically measured here"
        ]
        do {
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("MediaProbe", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("latest.json"), options: .atomic)
            exportError = nil
        } catch {
            exportError = "测试记录暂未导出；内存记录仍保留。请解锁后点重新导出，旧文件不能代表本轮。"
        }
    }
}
#endif
