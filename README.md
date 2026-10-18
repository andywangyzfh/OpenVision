# OpenVision 中文 / English MVP

This is Andy’s development fork of [rayl15/OpenVision](https://github.com/rayl15/OpenVision), for iPhone + displayless Ray-Ban Meta Gen 3. Original MIT attribution is retained in [LICENSE](LICENSE). Build **MVP/OpenVisionMVP.xcodeproj**, not the upstream full-feature project.

开发状态：核心代码已实现，尚未通过完整 iOS 本地与眼镜真机验收。详见 [验收标准](docs/acceptance-mvp.md) 和 [验证记录](docs/validation-mvp.md)。没有发布可安装的验收版本。

## 第一版功能

- 中文 / English 两个明确的语音模式；iPhone 原生语音识别和播报。
- 点击“开始对话”后分轮对话；回答播报结束再听下一轮；随时“停止”。
- 点击相机，或说“看看这个 / 拍照看看 / What do you see?”，临时启动眼镜相机，拍一张新照片后关闭，再询问模型。
- 官方 **Continue with ChatGPT** 登录，优先使用现有 ChatGPT 订阅额度。授权、账号资格及图片能力需实际账号验证；没有自动 API Key 付费回退。
- 仅前台运行；会话只在内存中，照片仅用于当前请求。清空会话和退出登录独立可用。

重型本地模型、连续视频、后台常驻、唤醒词、外部工具、笔记和人脸记忆不在 MVP 目标中。后续功能以 [GitHub Issues](https://github.com/andywangyzfh/OpenVision/issues) 管理，范围见 [backlog](docs/backlog-mvp.md)。

## 本地开发与测试

需要完整 Xcode（含 iOS Simulator）和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。CI 固定使用已验证的 **Xcode 26.6 / Swift 6.3.3**；本机安装同版可复现该环境。只有 Command Line Tools 时只能运行离线检查。目标 iOS 17.2+；Meta DAT 固定 1.0.1；真实设备/固件兼容性仍需验证。

```sh
brew install xcodegen
bash MVP/scripts/check-local.sh
# 完整 Xcode 下另运行 XCTest：
swift test --package-path MVP/Core
swift test --package-path MVP/Subscription
bash MVP/scripts/check-ios.sh
```

`check-local.sh` 执行 120 项核心行为断言、42 项认证/流处理断言、17 个实际对话 ViewModel 的异步场景，以及 Swift 语法解析、plist 校验及工程生成。ViewModel 测试使用实际生产代码，硬件/账号/模型传输为离线替身。**它不是 iOS 编译或完整验收通过。** `check-ios.sh` 选择已安装的 iPhone 模拟器并执行实际 App 构建/UI fixture 测试；测试结果写到忽略提交的 `.test-results/`。UI fixture 明确无网络、无麦克风，也不会伪造成功的硬件拍照。其通过不能替代眼镜/真实账号测试。

完整验收按 [两个 gate](docs/acceptance-mvp.md) 执行。GitHub CI 提供独立构建反馈，不能代替用户要求的本地测试。未通过本地 gate 前不进行 iPhone 安装。

## 本地 gate 通过后：iPhone 联调

1. 用数据线连接并解锁 iPhone，允许信任此 Mac；打开 iOS Developer Mode。
2. 打开 `MVP/OpenVisionMVP.xcodeproj`，选择 OpenVisionMVP scheme 和你的 iPhone，在 Signing & Capabilities 选择自己的 Team。无需提交签名文件或账号密码。
3. 首次调试使用官方 Meta AI App 的开发者模式。工程默认 `META_APP_ID=0`；在设置中“安装／更新官方开发组件”，连接／注册眼镜并单独授予相机权限。生产分发需按 Meta 官方流程配置 App ID/token。
4. App 设置中 **Continue with ChatGPT**，由你在系统授权页登录并同意授权；选择服务器返回的可用模型。不读取 Codex/ChatGPT App 的登录缓存。
5. 先关闭蓝牙麦克风选项，验证 iPhone 中文对话。再连接眼镜、断开其他蓝牙耳机，打开蓝牙输入并查看实际设备名，执行验收语料和拍照卡 A/B 测试。
6. 眼镜语音和拍照交替使用时，App 会先释放收音、临时拍照并关闭相机会话，再恢复语音。固件/HFP 限制仍需实测；失败时保留错误状态，不偷偷使用手机相机或旧照片。

免费 Apple 开发账号的设备签名有期限，后续通常需要重新由 Xcode 签名安装；实际期限以 Xcode/Apple 账号显示为准。TestFlight/正式分发在首轮验收之外。

## 登录与数据

订阅调用走官方 [Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source/sign-in) 和 [公开 Responses API](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)。当前集成支持文字和图片；语音在 iPhone 完成，不使用该授权调用音频/Realtime API。详见 [认证实现与限制](MVP/Subscription/README.md)。识别服务和模型仍可能需要网络；这不是完全离线方案。

新 App 不保存聊天到磁盘，不把照片写入相册，模型请求设置 `store:false`。这不等同于云端零处理/零保留承诺；服务端按相应服务政策处理请求。凭据使用独立 device-only Keychain 项，不在日志或 UserDefaults 中。

## 停用与恢复

在 App 中停止、清空会话、退出登录，并在 ChatGPT 的应用连接设置撤销授权，然后删除 OpenVision MVP。退出登录会清理本机凭据；远程撤销失败会显示提示。iOS Keychain 可能跨卸载保留，所以请先退出登录。

第三方对话逻辑运行在 iPhone App；眼镜连接和官方开发组件通过 Meta AI / DAT 管理，组件安装或更新由官方 App 完成。需要时从 Meta AI 中解除第三方连接，继续使用官方 App。尚未实测恢复过程，且不将软件可卸载等同于对退货/保修资格的保证。无需为了停用此 App 对眼镜执行出厂重置。
