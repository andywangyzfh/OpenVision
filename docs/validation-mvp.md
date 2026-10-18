# Validation record / 实测记录

2026-10-18：**Gate 1 本地软件验收 PASS；Gate 2 真机／真实账号 NOT RUN。** 没有安装到 iPhone，没有进行真实 GPT 推理或付费 API 调用。

测试源码：`b49c1db73780c18befc67cb4f6db5c84596874e0`。从该提交导出干净源码副本执行构建和测试；后续仅修改验收文档不改变被测代码。环境：macOS 26.6.2 (25G83)、Xcode 27.1 (27A9275)、iOS Simulator 27.1 (24A94425)、arm64；专用设备 `iPhone Duo OpenVision MVP`。Meta DAT 固定 1.0.1。Xcode 许可及首次初始化已由用户完成；命令通过 `DEVELOPER_DIR` 选择 Xcode，未修改全局 Command Line Tools 选择。

## 已执行的最终测试

| 套件 | 实际结果 | 验证边界 |
| --- | --- | --- |
| Core XCTest | PASS，17 项 | 实际语言、命令解析、轮次策略 |
| Subscription XCTest | PASS，8 项 | OAuth、请求、流、凭据及无缓存网络契约 |
| iOS Camera XCTest | PASS，14 项 | 生产控制层、真实 UIKit 图片重编码、GPS 清除；SDK 效果为替身；含真实未初始化 driver/service 安全回归 |
| iOS Speech XCTest | PASS，13 项 | 生产语音控制层；STT/TTS、时钟和音频效果为替身 |
| iOS Keychain XCTest | PASS，2 项 | 实际系统 Keychain CRUD、隔离、设备限定属性、恢复及退出清理；仅随机测试 service |
| Simulator UI XCTest | PASS，7 项 | 实际 App 启动、语言重启持久化、未知语言回退、界面、文字 fixture、照片失败、设置和实际后台恢复 |
| **XCTest 合计** | **61 通过，0 失败，0 跳过** | 包测试 25 项，xcresult 中平台及 UI 36 项 |

另执行 `check-local.sh`，全部通过：120 项 Core 断言、43 项 Subscription／JWT／SSE／网络隐私断言、53 个实际 VM 场景、28 个实际 URLSession 传输场景、13 个实际账号 Store 场景、61 项真实本机 loopback 回调断言，以及语法、plist、XcodeGen 检查。断言／场景数与 XCTest 方法数分开统计。HTTP 测试的请求均被拦截；回调仅访问 127.0.0.1，使用合成授权码。

实际构建使用 `xcodebuild build-for-testing`、generic iOS Simulator destination；完整执行使用 `test-without-building`、指定上述专用模拟器、关闭并行测试、临时本地签名 `CODE_SIGN_IDENTITY=-`。无需 Apple 账号、真实证书或手机。标准包测试使用完整 Xcode 的 `swift test`。

## Gate 1 逐项结论

| 条件 | 结果 | 对应证据 |
| --- | --- | --- |
| BUILD-01 | PASS | 固定提交干净副本生成／解析依赖并编译全部 App、宿主、平台及 UI target；0 编译／链接错误 |
| BUILD-02 | PASS | 上表 61 项 XCTest 及全部离线套件 |
| BUILD-03 | PASS | 正式启动 smoke 实际初始化 DAT，显示眼镜未连接，账号设置可访问；未恢复任何真实账号 |
| LANG-01 | PASS | 终止／重启中英持久化、旧值回退 UI；真实 SpeechService locale／缺声音／不可用识别回归 |
| LANG-02 | PASS | 短中文、空白、标点、重复 final／silence commit 及单次请求回归 |
| LANG-03 | PASS | 对应语言 prompt、Unicode SSE、完整中文／英文标点传给播报；MVP 不分段或截断播报，分段专属检查不适用 |
| LANG-04 | PASS | 指定中英拍照短语、普通摄影讨论反例、停止与连续视频反例 |
| TURN-01 | PASS | VM 取消／序列化／重试／旧回调；相机所有权；语音轮次身份 |
| TURN-02 | PASS | 播报时 STT 门控、旧转录／TTS 回调忽略、停止与显式重启 |
| PHOTO-01 | PASS | 实际控制层 A/B 新图、旧回调隔离，VM 后续历史不含旧 JPEG |
| PHOTO-02 | PASS | 无连接、拒绝权限、损坏／空图、各阶段失败及超时；无视觉请求／手机相机回退／虚构答案 |
| PHOTO-03 | PASS | 成功、失败、取消、超时清理；未确认关闭时保留句柄、阻止重叠并重试清理 |
| AUTH-01 | PASS | PKCE／state／回调／JWT／刷新／退出；实际独立 Keychain 测试 |
| AUTH-02 | PASS | 未登录、失效、空模型、额度拒绝与错误恢复；无付费回退；设置说明 |
| NET-01 | PASS | 28 个实际 client／URLSession 场景及 VM 对应错误／取消／重试 |
| PRIV-01 | PASS（可达源码审计） | 无生产 payload 日志或照片／聊天文件写入；凭据在 Keychain；HTTP 使用独立 ephemeral、禁用磁盘缓存／cookies／URL credential store；SDK 统计及崩溃上报 opt-out |
| LIFE-01 | PASS | VM／语音／相机清理回归，设置打开 Stop，实际系统应用切换确认后台后恢复 UI |

以上证明软件行为，不证明真实声学效果、镜头画质或硬件已释放。应用自身的存储／日志审计不构成 Apple、Meta 或模型服务端不处理／保留数据的承诺。系统浏览器 SSO 与有意保存在应用 Keychain 的登录记录也不同于 HTTP 缓存。

## 发现、修复及保留事项

初次 `b6a3809` 本地运行和 [CI 39111998790](https://github.com/andywangyzfh/OpenVision/actions/runs/39111998790) 均失败，未计为通过。未签名测试进程没有 Keychain 权限（-34018）；新增无账号／硬件初始化的独立测试宿主及仅模拟器使用的测试 entitlement，并采用临时本地签名后，实际 Keychain 测试通过。该测试 entitlement 不用于正式 iPhone App。

初次未签名 App 的 SDK 配置失败后仍访问 `Wearables.shared`，导致启动崩溃；现仅在 configure 成功后开放 SDK，失败时所有眼镜操作／回调均安全拒绝，保留文字与账号操作及双语提示。最终临时签名 App 的真实 configure 成功，处于未连接硬件状态；不能把 `META_APP_ID=0` 等同于初始化必然失败，也不能把初始化成功当成眼镜注册通过。

本机 iPhone Duo 模拟器的 synthetic Home 键未离开前台。后台 UI 改为实际打开系统 Settings，确认后台（含 suspended）状态后返回 App，验证暂停提示、相机关闭和可重新开始；没有放宽产品生命周期行为。

隐私复核发现默认共享 URLSession 依赖服务端缓存头。现登录／刷新／撤销、模型请求及身份元数据均使用 App 专用无缓存会话；没有清除系统共享缓存，未发现已缓存敏感内容的证据。

Xcode 留下 AVAudioSession 主线程激活／停用的运行时性能警告，以及 SDK build 编号解析／额外诊断收集工具路径警告。结构化结果仍为 36/36 Passed，未出现界面挂死；音频延迟和实际设备稳定性在 [issue #13](https://github.com/andywangyzfh/OpenVision/issues/13) 及 Gate 2 跟踪，不能用模拟器宣称解决。

## 证据及复现

本地完整证据（日志、结构化摘要、xcresult、源码 SHA 和环境）保存于本任务的 `outputs/OpenVision-MVP-validation/local-b49c1db/`，不提交原始用户内容。最终 xcresult：`Final-b49c1db.xcresult`。远程 [CI 39113878097](https://github.com/andywangyzfh/OpenVision/actions/runs/39113878097) 对应相同代码，状态以 Actions 为准；本地结论由本机实际运行建立。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash MVP/scripts/check-local.sh
swift test --package-path MVP/Core
swift test --package-path MVP/Subscription
# 可选：指定已安装的模拟器 UDID，及避免同步目录的构建目录
MVP_SIMULATOR_ID=<available-simulator-udid> MVP_BUILD_ROOT=/private/tmp/openvision-mvp-retest bash MVP/scripts/check-ios.sh
```

历史支持证据：[bafbb67 CI](https://github.com/andywangyzfh/OpenVision/actions/runs/39105717171) 的 17+7+3 测试曾通过；后续 `c6e0c1b` 本机完整 17+7+29+7 及离线检查通过；它们不代替最后的 `b49c1db` 结果。`c6e0c1b` 的远程运行因新提交被取消。

## Gate 2 保持 NOT RUN

真实 iPhone 安装／签名、眼镜注册及权限、实际中文／英文 STT/TTS 与蓝牙输入、HFP／拍照交替、真实 A/B 拍照、GPT 订阅账号授权及文字／图片推理、断网与锁屏中断、20 分钟稳定性测试，均待后续执行。按照用户要求，本轮不依赖手机。PR 保持 draft，跟踪 issue #1；尚不能称为真机验收或可发布版本。
