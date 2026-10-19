# Independent Submission Review / 独立测试计划审阅

## 2026-10-19 真机缺失MIME局部复核

独立submission_review只读核对b1c2ea5的3文件diff及network36日志，未自行实发或重跑，结论局部修复APPROVE。显式错误MIME仍拒绝，缺失MIME必须通过既有SSE/完成/非空文本。主agent随后正常真机2次完整短回答，第二次播报用户确认有声正常。#17的状态文案WIP未经过测试或本次Review，不在已安装版本中。用户已要求暂停；整体仍NOT ACCEPTED，见[检查点](checkpoints/2026-10-19-device-session.md)。

## 2026-10-19 正式独立复核

审阅者仍为独立只读 `submission_review`，未实现本轮修复、未自行重跑产品测试、未登录账号或调用模型。审查对象为固定源码、归档哈希和实际执行日志。

**测试计划 APPROVE；S0本地软件门槛 APPROVE；产品仍 NOT ACCEPTED。**

核验 `c5c375b8d4893c2d66db60a4c88231186f7cdac9` 的83项XCTest（17/14/42/10）及便携120/43/59/28/39/61全部通过；另核验仅测试变化的 `02e40d2629ff98586f138dbcd02ca0c1b869fe4b` 平台43项通过，0失败/0跳过。独立计算两个归档哈希，唯一差异为协调器测试文件，产品源码相同。不能把重叠的83与43相加；当前去重执行索引见 [213条记录](test-inventory-20261019.csv)。

A21正式App随机Keychain和实际AppSupport marker前置通过。A22删除失败、远端状态、新旧提交取消及冷启动门槛已有软件证据：即使marker与删除同时失败，也不会自动load/激活旧凭据；本人显式恢复或新授权是独立于持久化的门槛。物理记录未删必须继续报告清理未完成，不能声称安全清除。A23完整失败UI、A24实际协调器及隔离效果、A25身份/重定向边界已按各自层级覆盖。

保留边界：A24浏览器/token/身份验证网络效果为替身；HTTPS降级含delegate fixture；精确旧通知快照交错未直接确定性复现，仅有静态世代修复；10条音频主线程警告留在#13。以上不得写成实OAuth、实际TLS或设备性能已通过。**截至本轮软件审查，S1真实账号/模型/额度/刷新/撤销、S2手机/眼镜全部未验收。** 后续真机签名安装的实际进度见实测记录顶部；它不改变本次软件审查的证据范围。 用户提供的Pro、机型与Meta配对条件不是运行证据。

完整事实与证据位置见 [本轮实测记录](validation-mvp.md)。原A22“不静默恢复”标准没有放宽；O08调整为冷启动后本人一键恢复再验证真实模型，仍未测。

## 2026-10-18 历史计划审阅

审阅时间：2026-10-18。审阅者：独立子 Agent `submission_review`，未参与产品实现，仅只读核对计划、代码与既有证据。生产源码基线：`b49c1db73780c18befc67cb4f6db5c84596874e0`。

## 2026-10-18历史：正式结论

**测试计划 APPROVE；产品 NOT ACCEPTED。** 当前 [69组用例](test-plan-mvp.md) 与 [86条执行登记](test-cases-mvp.csv) 足以组织当前MVP范围的功能、异常、安全和生命周期验收；每一层证据与尚未执行的真实链路已分开。这个结论批准计划的可执行性和覆盖框架，不保证未知缺陷不存在，也不将历史自动测试视为真实功能可用。

**本轮没有复跑产品测试、没有修改产品代码、没有真实登录、模型调用或访问个人账号。** 读取CSV、核对证据行和源码位置属于文档验证。生产账号、联网、硬件用例必须实际执行后另给产品验收结论。

## 2026-10-18历史：核查范围与结果

| 审阅项 | 实际核查 | 结论 |
| --- | --- | --- |
| 自动测试索引 | 158条=61 XCTest方法+94具名portable场景+3套件汇总；逐条核对具名case、证据行、源码文件/方法位置 | 无错配；120/43/61汇总断言没有被伪造成逐断言日志；不能将这些数字相加称独立功能覆盖 |
| 既有实测结果 | 本地摘要36/36、Core17、Subscription8及portable日志；CI39113878097最终success | 原集合通过；不是产品通过 |
| 产品执行登记 | 86个唯一ID=25本地+18在线+43设备行；19个既有已测行填限定PASS，A19为SOURCE REVIEW ONLY，其余实际结果留空 | 状态与现有事实一致；20项生命周期条件和2项权限已独立登记 |
| 模拟器/正式入口 | fixture/smoke差异；完整OAuth协调器；生产Keychain与独立空宿主的区别 | 系统浏览器全链路及生产冷恢复均未测；不能用smoke替代 |
| 签名前置疑点 | 检查最终主App的app-Simulated.xcent及MachO内嵌entitlements | 有application-identifier；不能断言主App缺权限。实际主App读写前置仍需A21验证 |
| 照片与语音 | driver替身边界、无本地图导入入口、照片关闭时序、STT/TTS实际体验 | 控制层通过不证明真机；H12必须5张成功新图正确识别三属性，且相机在模型回答/播报前实际关闭 |
| 安全及完整性 | Keychain删除返回码、协调器迟到令牌、元数据来源/重定向、HTTP缓存设置、旧静态审计引用 | 删除失败为开放缺口；其余待补测，不宣称安全完备 |
| 官方流程资料 | OpenAI授权/模型/会话/预览限制与Apple系统授权文档，核对plan/available credits消费说明 | 不保证当前账号资格或模拟器loopback组合一定成功；无API Key不自动证明不消耗已有credits |

## 2026-10-18历史：审阅中要求的修正（已落入计划）

- 修复Markdown表内空白断行，避免69组用例无法正常呈现。
- 已测CSV行填入限定的历史结果与完整SHA，静态审计单列；本轮未复跑的事实明确保留。
- H12不能把“看不清”算成功，需要五张成功新图、当前卡颜色/形状/数字正确、真实关闭及时序证据；App标签本身不够。
- O14明确刷新计数/持久化观测入口待备，不抓取真实token；不能仅凭点两次刷新就宣称single-flight经过真实验证。
- H10拆为麦克风和语音识别两个权限记录；H18～H21拆成20个生命周期记录。
- 标明单注册账号限制、O17图片探针入口尚未准备、正常生产App账号恢复从未验证。
- 成本边界为优先且仅用套餐包含额度；已有credits若可能参与且无法排除，应停止并单独取得该选择，不能擅自消费或购买。

## 2026-10-18历史：产品仍未通过的阻塞/待处理项

| 项目 | 事实与要求 | 跟踪 |
| --- | --- | --- |
| A22，P0退出安全 | `clear/delete`忽略SecItemDelete结果。需修复并验证删除失败、退出、冷启动、迟到刷新和恢复；没有声称真实用户删除曾失败 | [#14](https://github.com/andywangyzfh/OpenVision/issues/14) |
| A21，生产App Keychain | 空TestHost成功不能代替主App的host-id/凭据读写前置。先用合成数据完成，不让用户先登录试错 | [主任务#1](https://github.com/andywangyzfh/OpenVision/issues/1) |
| A23～A25，新增本地异常覆盖 | 完整配置失败UI、AccountService取消/迟到令牌、身份元数据及重定向边界仍需补测或明确Review处置；不要用真实凭据试跨域 | [#15](https://github.com/andywangyzfh/OpenVision/issues/15) |
| S1，真实联网 | O01～O18中真实授权、回调、token/JWKS、目录、推理、持久恢复、退出/撤销均未执行；先做文字，模拟器组合本身待确认 | [测试计划](test-plan-mvp.md) |
| S2，手机与眼镜 | 实际安装、识别/发音/路由、照片/HFP、活动阶段中断、退出/停用恢复及20分钟稳定性均未测 | [测试计划](test-plan-mvp.md)；[音频警告#13](https://github.com/andywangyzfh/OpenVision/issues/13) |

计划改变后需重新审阅受影响行；代码改变后必须记录新SHA并重新执行受影响测试。P0失败不得靠调低优先级、改统计口径或以其他层PASS代替。条件P1尚未执行时，需保留未测并明确Review批准的替代证据/延期范围。

## 2026-10-18历史：减少用户反复参与的安排

Agent先完成无需账号的技术前置和安全修复。一次收齐：唯一账号/工作区别名与套餐类型、本人可操作官方登录/MFA及撤销的时间、仅套餐额度边界、网络情况；后续一次提供iPhone/iOS/签名、Meta配对/开发模式/固件及可测试时间。本人只在官方界面输入秘密、确认权限和参与真实语音/镜头验证，不向Agent提供密码、验证码、token、OAuth code或私钥。

具体最短顺序、在线尝试上限、20分钟合并语料/照片会话和逐项记录格式均在 [完整计划](test-plan-mvp.md) 中。

官方依据：[OpenAI授权](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)、[模型](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)、[会话](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)、[限制](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)、[plan/available credits](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt)、[Apple授权会话](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)。
