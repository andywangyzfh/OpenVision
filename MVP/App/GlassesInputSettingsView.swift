import OpenVisionCore
import SwiftUI

struct GlassesInputSettingsView: View {
    @ObservedObject var service: GlassesInputService
    let language: ConversationLanguage
    private var chinese: Bool { language == .chinese }
    var body: some View {
        Section(chinese ? "眼镜双击语音（实验功能）" : "Glasses double-tap voice (experimental)") {
            Toggle(chinese ? "允许眼镜触控语音" : "Allow glasses gesture voice", isOn: Binding(
                get: { service.isEnabled }, set: { service.setEnabled($0) }))
                .accessibilityIdentifier("inputs.enabled")
            Text(chinese ? "打开开关后，点下方按钮进入双击待命；返回主界面，双击镜腿才开始收音。再次双击停止。本 App 的语音操作不会开启相机。App 离开前台（包括系统权限弹窗）后需重新开启待命。" : "Turn on the switch, then enable double-tap standby below. Return to the main screen and double-tap the temple to start listening; double-tap again to stop. This app's voice controls do not open the camera. Enable standby again after the app leaves the foreground, including a system permission prompt.")
                .font(.caption)
            Button(chinese ? "开启双击待命" : "Enable double-tap standby") { Task { await service.arm() } }
                .disabled(!service.canArm)
                .accessibilityIdentifier("inputs.arm")
            Button(chinese ? "停止手势待命" : "Stop gesture standby") { service.disarm() }
                .disabled(!service.isArmed && !service.isArming && !service.isCleaningUp)
                .accessibilityIdentifier("inputs.disarm")
            Text(service.statusText(language: language)).font(.caption)
                .accessibilityIdentifier("inputs.status")
            Text(chinese ? "需要兼容的眼镜固件及 Meta 触控功能授权。单击、长按和拍摄键仍由眼镜系统处理；此设置不修改它们的原生行为。" : "Requires compatible glasses software and Meta gesture access. Single taps, holds and the capture button remain glasses system controls; this setting does not change their native behavior.")
                .font(.caption2)
        }
    }
}
