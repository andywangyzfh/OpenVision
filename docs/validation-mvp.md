# Validation record / 实测记录

## 暂停检查点（2026-10-19）

用户要出门断开手机，**真机测试已停止，等待本人要求继续**。已安装并实测b1c2ea5，Debug0.1.0(2)：官方授权、目录、显式恢复及2次真实算术回答成功；第二次短中文模式播报由用户确认“有声，没问题”。总手动推理尝试5次（旧版3未完成/调试中断，修复版2完成）；无原始中文长输入或英文/上下文通过证明。

[#16](https://github.com/andywangyzfh/OpenVision/issues/16)缺失MIME问题已修复：局部network36、flow59、Subscription XCTest14、正式iOS构建签名安装通过，独立局部Review批准；没有把旧84项整套结果说成新提交全量复跑。新发现[#17](https://github.com/andywangyzfh/OpenVision/issues/17)播报完成/Stop文案残留；VM修复WIP已落盘、**未做回归/编译，未装到手机**。下一次先补验证再安装。逐项事实、产物hash、未发英文草稿、剩余用例及恢复顺序见[完整检查点](checkpoints/2026-10-19-device-session.md)。真实STT、眼镜与图片仍未验收，整体NOT ACCEPTED，主issue开放/PR为draft。

## 本轮真机与真实账号进度（2026-10-19，产品未验收）

用户完成开发者信任后，真实iPhone15ProMax / iOS27.0.1 (24A446) 上的正式App合成Keychain CRUD、实际AppSupport marker预检及无测试参数正常启动均PASS。签名构建/安装、codesign与手机/Bundle匹配已通过；免费开发配置到2026-10-26，可由Xcode重新签名。安装版本0.1.0 (1)，来源02e40d2（产品等价c5c375b）；可执行文件SHA256为`6228e7b6cfb5042e31bb63eb025019f7c5f91f7ddd1dc0f0c0530ea1ab2f6932`。CI [39221241977](https://github.com/andywangyzfh/OpenVision/actions/runs/39221241977) 在2107e0d成功。

**真实官方授权功能通过**：auth.openai.com账号页可达；X取消回未登录并能重开；用户亲自授权后回App，真实账号及非空模型目录出现，手动刷新和GPT-6.1-Sol选择完成。O02取消的动态零请求/迟到回调证明及O16动态隐私检查尚未完成。官方Usage页在推理前核验额外credits=0、自动充值关闭；未购买/使用reset/改消费设置。O18每App及事后归属仍未核对。

**真实推理FAIL，跟踪[#16](https://github.com/andywangyzfh/OpenVision/issues/16)**：公开`1+2`共3次手动尝试，无完成答案。调试确认HTTP200且Content-Type及Foundation MIME缺失，生产client格式guard抛malformedResponse。仅查看状态/MIME及header名字，未导出响应正文、完整headers或凭据。第三次在定位后尝试调试跳转导致异步栈EXC_BAD_ACCESS，已终止并正常重启；该次单列调试中断，不当作产品成功或正常运行崩溃。最小兼容修复及本地回归进行中，不能宣称中文问答可用。

冷重启已观察账号未激活、发送禁用；完整显式恢复仍未完成。App显示眼镜未连接/相机关闭，不能用标签证明硬件状态。真实语音、眼镜、新图、退出/撤销/自然刷新、动态日志及稳定性仍未验收。脱敏本地证据见task outputs/OpenVision-MVP-validation/device-20261019/after-trust-report.md；未发布账号截图、邮箱、设备标识或签名秘密。**整体NOT ACCEPTED，PR保持draft。**

2026-10-19 第一轮本地回归结论：**S0 本地软件门槛已获独立 Review APPROVE；产品整体仍 NOT ACCEPTED。** 当时S1/S2未执行；后续真机安装进度见顶部。没有读取其他 App 的凭据，也没有进行真实模型或付费 API 调用。

## 本轮固定源码与执行结果

| 执行 | 固定源码 | 实际结果 |
| --- | --- | --- |
| 干净源码、clean iOS build、整套 XCTest | `c5c375b8d4893c2d66db60a4c88231186f7cdac9` | **83 PASS**：Core 17、Subscription 14、平台42、UI10；0失败/0跳过。实际 App 普通冷启动、Keychain+AppSupport 前置和中英配置失败 UI 均通过 |
| 便携回归 | 同上 | Core120、Subscription43、实际VM59、HTTP28、Store39、真实本机callback61全部通过；这些是不同粒度的断言/场景，不能相加当独立功能数 |
| 仅追加迟到失败测试后的完整平台回归 | `02e40d2629ff98586f138dbcd02ca0c1b869fe4b` | **43 PASS**：实际协调器12、Keychain4、相机控制14、语音控制13；0失败/0跳过 |

两次归档逐文件SHA256核对：唯一差异为 `MVP/PlatformTests/AccountCoordinatorTests.swift`，产品源码完全一致。后一轮替代前一轮平台42项并新增一项，**不能把83+43算成126个独立测试**。当前 [执行索引](test-inventory-20261019.csv) 去重后为84个XCTest方法、126个具名便携场景、3条仅有汇总证据的套件记录（合计213条记录，不是213项独立功能）。[旧158条索引](test-inventory-mvp.csv) 保留为b49历史证据。

环境仍为 macOS26.6.2 / Xcode27.1 / iOS Simulator27.1、arm64、DAT1.0.1。Git归档导出后替换整个MVP源码目录；`xcodebuild clean test`重新构建，SwiftPM使用独立scratch。SDK/依赖缓存复用不等于复用测试结果。

## 安全缺口收口与证据边界

- **A21**：实际App可执行文件内随机Keychain service读/写/更新/删；默认AppSupport目录随机marker的missing→block→allow→block读回及清理通过。不会读正式账号记录；模拟器签名环境通过不替代iPhone签名。
- **A22**：删除结果传播；远程撤销为confirmed/notNeeded/unconfirmed，失败的新凭据事务不能继承旧确认。marker先阻断再删，删除失败保留可见清理入口；两处持久化同时失败仍报告未安全清除。**每次冷启动Store不load、不激活账号；必须本人显式恢复或新OAuth**，故残留不会静默登录。这个门槛不谎称物理记录已被删除。
- **A23**：完整App配置失败分支的双语说明及禁用眼镜操作通过；文字账号界面仍可打开。
- **A24**：实际AccountService及Store执行，浏览器、token/JWKS网络、元数据为隔离替身。token/身份阶段取消、Task.cancel、重入、迟到成功与失败、本人resume互斥、真实Store失效通知及可见提示均有执行证据。**不证明实际OpenAI浏览器授权或iOS loopback组合兼容**；它们仍是O03未测。
- **A25**：元数据/JWKS拦截fixture和生产session真实本机跨端口3xx拒绝通过。HTTPS降级/同源策略含delegate fixture，不是真实TLS/外站端到端测试。
- 精确“旧通知快照挂起后覆盖新cleanup”的特定交错采用静态世代修复，尚未直接确定性复现该交错；没有标成独立已测通过。Review接受本轮S0范围。
- 完整模拟器运行仍记录10条音频主线程警告；[#13](https://github.com/andywangyzfh/OpenVision/issues/13) 保留，真机性能没有被宣称解决。

本轮静态隐私审计为 `privacy-review-current-c5c375b.txt`，配套66文件源码哈希。它不是O16/H22动态日志/容器检查；后两项仍未测。

本地证据目录：`/Users/andywang/Documents/Codex/2026-10-15/bang-wo/outputs/OpenVision-MVP-validation/local-c5c375b/`。内含两份源码tar、两个xcresult、summary、全部日志、源码清单与等价性记录。它不包含真实账号凭据或私人语料。可用 `MVP/scripts/export-test-inventory-current.py --evidence <该目录> --output <CSV>` 重建当前索引。

下一步先进行独立的官方Pro授权及有上限的真实文字验收；模型资格、套餐/已有credits归属、真实恢复/刷新/退出均必须实际记录。无需先连接手机。iPhone/iOS精确版本、签名、Meta注册/权限、音频和新图仍留在S2。

## 2026-10-18 历史执行记录

2026-10-18 更新：**整体 NOT ACCEPTED。原有61项本地自动测试通过，但不等于真实登录/联网可用，也不证明所有安全边界完整。** 独立Submission Review新增A21～A25，其中A22发现退出凭据删除失败不被报告，跟踪[#14](https://github.com/andywangyzfh/OpenVision/issues/14)；其余补测跟踪[#15](https://github.com/andywangyzfh/OpenVision/issues/15)。截至2026-10-18当时扩展S0未闭合；2026-10-19结论见顶部。S1真实订阅/联网、S2手机/眼镜均未测。完整逐项状态以 [测试清单](test-plan-mvp.md) 和 [独立Review](test-plan-review-mvp.md) 为准。

以下保留原固定提交的**历史执行证据**；没有重新执行b49固定提交；2026-10-19新源码的83项整套与后续平台回归见顶部。两轮均没有安装到iPhone、真实登录、模型推理或付费API调用。旧“Gate 1 PASS”只适用于旧清单，不能继续作为安全完备或产品可用的结论。

测试源码：`b49c1db73780c18befc67cb4f6db5c84596874e0`。从该提交导出干净源码副本执行构建和测试；后续仅修改验收文档不改变被测代码。环境：macOS 26.6.2 (25G83)、Xcode 27.1 (27A9275)、iOS Simulator 27.1 (24A94425)、arm64；专用设备 `iPhone Duo OpenVision MVP`。Meta DAT 固定 1.0.1。Xcode 许可及首次初始化已由用户完成；命令通过 `DEVELOPER_DIR` 选择 Xcode，未修改全局 Command Line Tools 选择。

## 2026-10-18历史：已执行的最终测试

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

## 旧17项本地条件的历史证据（不含新增A21～A25）

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

## 2026-10-18历史：发现、修复及保留事项

初次 `b6a3809` 本地运行和 [CI 39111998790](https://github.com/andywangyzfh/OpenVision/actions/runs/39111998790) 均失败，未计为通过。未签名测试进程没有 Keychain 权限（-34018）；新增无账号／硬件初始化的独立测试宿主及仅模拟器使用的测试 entitlement，并采用临时本地签名后，实际 Keychain 测试通过。该测试 entitlement 不用于正式 iPhone App。

初次未签名 App 的 SDK 配置失败后仍访问 `Wearables.shared`，导致启动崩溃；现仅在 configure 成功后开放 SDK，失败时所有眼镜操作／回调均安全拒绝，保留文字与账号操作及双语提示。最终临时签名 App 的真实 configure 成功，处于未连接硬件状态；不能把 `META_APP_ID=0` 等同于初始化必然失败，也不能把初始化成功当成眼镜注册通过。

本机 iPhone Duo 模拟器的 synthetic Home 键未离开前台。后台 UI 改为实际打开系统 Settings，确认后台（含 suspended）状态后返回 App，验证暂停提示、相机关闭和可重新开始；没有放宽产品生命周期行为。

隐私复核发现默认共享 URLSession 依赖服务端缓存头。现登录／刷新／撤销、模型请求及身份元数据均使用 App 专用无缓存会话；没有清除系统共享缓存，未发现已缓存敏感内容的证据。

Xcode 留下 AVAudioSession 主线程激活／停用的运行时性能警告，以及 SDK build 编号解析／额外诊断收集工具路径警告。结构化结果仍为 36/36 Passed，未出现界面挂死；音频延迟和实际设备稳定性在 [issue #13](https://github.com/andywangyzfh/OpenVision/issues/13) 及 Gate 2 跟踪，不能用模拟器宣称解决。

## 2026-10-18历史：证据及复现

本地完整证据（日志、结构化摘要、xcresult、源码 SHA 和环境）保存于本任务的 `outputs/OpenVision-MVP-validation/local-b49c1db/`，不提交原始用户内容。最终 xcresult：`Final-b49c1db.xcresult`。远程 [CI 39113878097](https://github.com/andywangyzfh/OpenVision/actions/runs/39113878097) 对应相同代码，现已完成并为 **success**；这些仍只证明相同的自动测试，不证明真实账号或眼镜。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash MVP/scripts/check-local.sh
swift test --package-path MVP/Core
swift test --package-path MVP/Subscription
# 可选：指定已安装的模拟器 UDID，及避免同步目录的构建目录
MVP_SIMULATOR_ID=<available-simulator-udid> MVP_BUILD_ROOT=/private/tmp/openvision-mvp-retest bash MVP/scripts/check-ios.sh
```

历史支持证据：[bafbb67 CI](https://github.com/andywangyzfh/OpenVision/actions/runs/39105717171) 的 17+7+3 测试曾通过；后续 `c6e0c1b` 本机完整 17+7+29+7 及离线检查通过；它们不代替最后的 `b49c1db` 结果。`c6e0c1b` 的远程运行因新提交被取消。

## 2026-10-18历史：Gate 2 保持 NOT RUN

真实 iPhone 安装／签名、眼镜注册及权限、实际中文／英文 STT/TTS 与蓝牙输入、HFP／拍照交替、真实 A/B 拍照、GPT 订阅账号授权及文字／图片推理、断网与锁屏中断、20 分钟稳定性测试，均待后续执行。按照用户要求，本轮不依赖手机。PR 保持 draft，跟踪 issue #1；尚不能称为真机验收或可发布版本。

本轮已重新生成静态审计 `privacy-review-current-b49c1db.txt`（同本地证据目录），记录当前b49生产源码与SHA256；它替代旧文件中混合c6e0c1b/后附说明的审计引用，但不替代O16/H22动态日志与容器检查。
