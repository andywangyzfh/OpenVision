# OpenVision checkpoint — 2026-10-19

**后续本地检查点：e8a726727f17956f40cdcf05dbcdcd5bc1e6fbb1；手机仍保持暂停。** 新语音/相机安全范围本地软件已获独立多agent APPROVE。当前平台57、最终UI25、Core17、Subscription14的分组运行覆盖113个不同方法；另有Flow109、Inputs25，不能重复加总。完整82的79/3与81/1失败、中断UI15的真实设置失败和取消均保留。新增固定footer返回设置入口，未声称原native Done已修好。证据和范围见[本机回归](../local-benchmark-mvp.md)与[独立Review](../test-plan-review-mvp.md)。

语音优先，按需识图保留共同验收；默认关闭的前台镜腿双击待命[#20](https://github.com/andywangyzfh/OpenVision/issues/20)、每次确认/一次性相机授权[#19](https://github.com/andywangyzfh/OpenVision/issues/19)、phone排队Start防Stop后复活[#22](https://github.com/andywangyzfh/OpenVision/issues/22)均已本地验证，真实手势/指示灯/硬件未测。**本轮没有操作手机、实际麦克风/相机或真实授权/模型；安装版本仍旧b1c2ea5 / 0.1.0(2)，本次修改未装机。** 原Xcode/手机信任已完成，恢复时无需重复要求。

Mac模型比较入口已准备并Review；实际登录、最多39次pilot和模型排名仍NOT RUN（[#18](https://github.com/andywangyzfh/OpenVision/issues/18)）。下次由用户恢复实际阶段后：先确认本次消费限制/当前官方额度，再进行本机独立官方授权和比较；手机随后重新连接解锁、正常签名安装新build，显式恢复本App登录，按G06/G07及真实STT矩阵测试。先在私人环境确认摄像头指示灯，若任何意外亮灯立即停测记P0。Inputs需官方能力/兼容固件；不使用拍摄键作为语音触发，也不承诺锁屏/后台激活。产品仍NOT ACCEPTED，主issue开放、PR为draft。

## 以下为出门前历史记录（当时的WIP说明已由上方本地验收更新）

## 已安装且已测试的版本

手机：iPhone 15 Pro Max，iOS 27.0.1 (24A446)，有线配对，Developer Mode及开发者信任已完成。免费开发配置到2026-10-26，之后可用原Personal Team重新签名安装。不得重复索要这些已完成的准备。

安装源码 **b1c2ea5cd641e398cb74638bfe475a31bad5b3d7**，正常Debug **0.1.0 (2)**，Bundle com.andywang.openvision.mvp。产物清单见本地header-fix-b1c2ea5/missing-mime-build-manifest.json；51个Swift/资源文件核对，只有Info.plist字节排版不同且解析值完全相同。本地签名选择、build version=2只在临时工程/构建参数；签名私钥/账号信息未提交。

b1c2ea5局部修复：真实接口HTTP200不带Content-Type时，继续严格解析SSE/完成/非空文本；显式错误MIME仍拒绝。已执行NetworkChecks **36/36**、实际VM FlowChecks **59/59**、Subscription XCTest **14/14**、真实iOS设备构建及签名校验/更新安装。独立submission_review局部APPROVE；不是整套84项XCTest在新提交复跑。

## 真实验收事实

- H01：安装、本人信任、正常启动PASS；正式App随机合成Keychain CRUD及真实AppSupport marker预检PASS。
- O03：本人在auth.openai.com为OpenVision Bilingual完成授权，回App有真实账号；生产验证/Store功能路径完成。未导入Codex凭据、未提供API Key。
- O04：真实目录手动刷新非空，实际选择GPT-6.1-Sol。
- 共 **5次手动推理尝试**：旧版本3次未完成（前2次MIME guard拒绝；第3次定位后LLDB控制流实验中断）；修复版2次完整回答，均无调试器/fixture。输入都是公开ASCII `1+2`，回答分别“1加2等于3。”、“3。”。**不是原O05完整中文输入语料已通过**。
- 第一次声音未确认（用户没开声音）。按用户要求重播，用户明确回复“有声，没问题”。仅证明本次短中文模式播报，未证明长中文、英文、眼镜音频或STT。
- O08：修复版正常冷启动先未激活/发送禁用；显式点击“恢复本机已有登录”后真实账号/目录恢复，随后推理成功。该恢复UI操作由agent在用户已授权的会话中执行，不是后台自动恢复。动态零请求/秘密日志检查仍待O16。
- O02：官方页/X取消返回未登录/重开UI通过；没有用UI结果伪称动态请求计数或任意迟到回调均已测。
- O18：推理前官方Usage credits=0、自动充值off；没有购买、reset、修改消费设置或切后端。每App及事后归属检查仍未执行。

## 缺陷和未测

- #16：缺失MIME阻断已由b1c2ea5修复并正常真机2次完成验证。
- #17：播报结束后“正在播报”文案残留；Start/输入已启用，用户也确认声音正常，是状态文字缺陷。**WIP修改已落盘但未执行任何parse/编译/新增回归，不在手机安装版本中。** 改动仅ConversationViewModel.swift；完成、preview完成及Stop清过期活动文案，保留错误/暂停提示。用户要求暂停时已冻结agent；恢复后必须补回归、review和构建再安装，不能将WIP当已验收。
- 英文模式已选择，但英文问题受输入法改写，**草稿未发送**，不得计入模型次数或英文通过。下次先清草稿/确认输入法；手机可能保留英文界面，重启会清会话草稿。
- 中文原始长输入、英文/切回中文、上下文、Stop/重试、自然刷新、退出/重新登录/远端撤销、断网、O16动态隐私尚未完成。
- 麦克风未开启；真实STT、蓝牙/眼镜输入、Meta注册/组件/相机授权、新图问答、HFP、生命周期矩阵、20分钟稳定性及#13音频性能均未验收。App的“眼镜未连接/相机关闭”只是UI，不证明硬件状态或Meta配对失败。
- 调试中断需保留：旧版本第3次定位后LLDB thread jump到异步栈另一源码行，导致EXC_BAD_ACCESS；已kill并正常重开。这是调试控制流改变造成的中断，不是正常App crash或成功证据。不得再用这种跳转验证真实流。

## 继续顺序

1. 用户明确回来要求继续后，先查看仓库当前HEAD、WIP和本检查点；不读取其他App凭据/账号截图。
2. 完成#17的实际VM中英完成/Stop/迟到事件/连续监听回归和Review，正常iOS构建后安装下一build。保留本地签名工程于/private/tmp/openvision-device-20261019/MVP/OpenVisionMVP.xcodeproj（勿无意重生成丢Team；tmp可能被清理，持久源码在repo）。
3. 重新接线解锁；正常启动先显式恢复已有授权。若服务端已过期/撤销才在官方页面让用户重授权，不保证永远免登录。
4. 优先一次请求同时验证真实中文输入、修复后完成文案与实际听感；再做英文与上下文。原初文字会话cap10次，目前已用5次，恢复前重新确认该上限是否仍适用；不得自动扩大或声称取消不耗套餐额度。
5. 之后才安排用户现场说固定语料、Meta注册/权限和公开新图测试；不得在用户出门期间后台开麦/拍照。
6. O18事后额度/归属、O16动态隐私、退出/撤销及其他矩阵仍逐项登记，保持#1开放、PR#12为draft，整体 **NOT ACCEPTED**。

## 本地证据与GitHub

- `outputs/OpenVision-MVP-validation/device-20261019/header-fix-b1c2ea5/`：固定源码tar、构建hash清单、network36/flow59/Subscription14日志及局部Review摘要。原c5/02完整本地证据仍单列，不能相加重叠数量。
- 原始签名构建日志、设备标识和账号截图不进入GitHub。公开记录只用账号别名。
- Fork https://github.com/andywangyzfh/OpenVision ，branch mvp/bilingual-voice-photo，draft PR#12，main#1，header#16，status#17，audio#13。
