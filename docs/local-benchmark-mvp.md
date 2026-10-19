# 本机回归与模型比较

状态（2026-10-19）：手机测试继续暂停；用户已要求继续本机工作。模型实时速度尚未测，不能据此推荐最快模型或改变MVP默认模型。本机官方授权入口不读取Codex/ChatGPT缓存，也不搬运手机Keychain。实际执行结果见validation-mvp.md。

跟踪：[本机测速 #18](https://github.com/andywangyzfh/OpenVision/issues/18)、[播报状态 #17](https://github.com/andywangyzfh/OpenVision/issues/17)。Mac入口已完成Swift6正式构建、公开夹具自检、14项生命周期检查、报告自检及独立Review，状态为READY FOR USER AUTHORIZATION。首屏已核对登录前额度确认及开始按钮均禁用，未登录、未调用模型。当前本机尚无真实OAuth或模型测速结果。

| 本机能完成 | 证据边界 |
| --- | --- |
| 实际VM、SpeechService、真实SwiftUI的完成、Stop、迟到事件和键盘布局回归 | 模型/语音平台效果可控替身；必须走真实完成回调，不能靠preview早返回 |
| 生产客户端SSE/错误/计时回归 | 无账号；合成时钟和传输不能用于模型速度排名 |
| Mac上的真实中英、上下文、合成图片及模型接口比较 | 需要本人为本机工具独立官方授权；不证明手机、蓝牙、可闻TTS或眼镜延迟 |
| 设备专属能力 | 眼镜注册/相机授权、新镜头照片、HFP、真实手机收音、热量/电量仍需手机/眼镜 |

## 本轮本地执行登记

| 项目 | 实际执行 | 结果与边界 |
| --- | --- | --- |
| 旧版播报状态复现 | b1c2ea5的实际VM，在平台完成回调后检查status | FAIL，精确出现“正在播报…”残留；这是修复前复现证据 |
| 修复后的实际VM | 新增状态focused13与全Flow72 | PASS；focused13包含在72内，不能相加；SpeechDriver/模型效果替身 |
| 首轮完整模拟器 | 平台43、UI19 | 54 PASS / 8 FAIL / 0 skip；保留失败记录，不能用编译成功代替UI通过 |
| 首轮布局修复定向模拟器 | 旧文字Clear、中文两轮、英文停止Thinking | 2 PASS / 1 FAIL；前两项通过，英文Send hittability仍失败；后续紧凑布局和可停止性修复另行验证 |
| 旧范围定向UI与完整回归 | 定向5项全过；随后完整64项 | **63 PASS/1 FAIL**；完整英文focus失败保留，不以定向通过覆盖 |
| 新相机/触控首轮联合 | 平台Photo19、Joint9、UI5 | **23 PASS/10 FAIL**；19Photo+2Joint+2Status通过，7Joint+2PhotoUI+1InputsUI失败；日志与源清单保留 |
| 新实际VM与Inputs | Flow109、Inputs25 | PASS，效果替身；Flow含inactive保留账号/后台取消，不证明真实OAuth |
| 新联合第二轮 | 35项 | **33 PASS/2 FAIL**；平台28通过，滑动/开关UI失败保留 |
| 准确手势/控件修正后定向 | 2项UI | **2 PASS/0 FAIL/0 skip**；原生确认框实际关闭且请求取消，SDK未就绪明确提示；不是硬件证明 |
| 新完整回归第一轮 | 平台57+UI25 | **79 PASS/3 FAIL/0 skip**；3个旧设置用例未滚到相机控件，原断言保留后修正定位；11项播报/键盘全过 |
| 新完整回归第二轮 | 修正定位后平台57+UI25 | **81 PASS/1 FAIL/0 skip**；设置滚动后Done不可用，保留失败 |
| phone Start排队竞态修复后UI | 因Done无效点击而主动中断 | Xcode原始15项13PASS/2FAIL；实际断言失败1、主动取消1，剩余10未完成 |
| 固定footer返回入口后完整UI | UI25 | **25 PASS/0 FAIL/0 skip**；含11项播报/键盘、设置关闭及后台恢复；未声称原native Done已修复 |
| 当前XCTest软件覆盖 | 平台57+最终UI25+Core17+Subscription14 | **113个不同方法各自运行PASS**；平台及包源码字节等价后复用，不是单次113或82项整套全绿 |
| 40项静态隐私及独立验收 | 固定e8a7267源/证据 | APPROVE仅本地软件；动态隐私/账号/硬件均不由此通过 |
| 基础包XCTest | Core17、Subscription14 | PASS；仅本机软件，不是真实账号调用 |
| 生产传输与计时 | HTTP36、timing13 | PASS；HTTP拦截、合成时钟，不产生模型性能数值 |
| Mac工具正式构建/控制逻辑 | Swift6 build、公开夹具、生命周期14、报告self-test | PASS；无真实授权/模型请求；独立Review可进入本人授权 |
| Mac真实授权、39次比较、逐答案质量Review与模型暂选 | 尚未执行 | NOT RUN；需本人独立官方登录及当前账号消费设置确认 |
| 真机、眼镜、实际STT/首音/蓝牙延迟 | 本轮暂停 | NOT RUN；保留之前手机短回答及一次播报通过的历史证据，不外推至这些能力 |

实际证据保存在任务的 `outputs/OpenVision-MVP-validation/local-followup-20261019/`，包括失败与通过日志、源码SHA256、Mac正式来源manifest。最终UI25、109Flow及40项静态证据已由独立agent核验并批准本地软件范围；历史失败不删除。实际手机仍为旧b1c2ea5，新修复未安装。

## 一次本机模型比较

本机工具的三个步骤：官方登录、打开本次账号的官方用量页、确认只使用套餐额度后开始。额外credits必须为0且自动充值关闭；该勾选是本次用户确认，不把上次手机观察当本次账户证明。不购买额度、不使用reset、不提供API Key、不读已有凭据。新的token只在本次进程内存中；结束/失败/取消尝试撤销本工具的会话，远端未确认会如实记录。

候选为本次真实目录中的gpt-6-luna、gpt-6-sol、gpt-6.1-sol，显式不支持image的条目排除。目录不足则停止，不换后端；不能预先承诺本账号一定返回这些候选。模态元数据缺失仍记unknown；先用公开合成图探针检查，再对全部答案（包括探针）做语义质量审阅，词语命中不等于理解正确。

最多39次推理：每模型1次fresh URLSession图片探针（3次，不参与暖样本排名），然后每模型×4项任务×3次（36次）。同一生产client、请求体与语言systemPrompt；固定轮转顺序交错模型，manifest保存精确顺序。fresh URLSession不等于冷进程、冷TLS或冷模型；后端缓存和当时负载无法被本工具控制。

任务：中文日常建议、英文简短建议、固定公开历史中的数字42、公开合成图颜色/形状/数字。图片由本机画出512×512 JPEG，记录SHA256，完全不读相机、照片库、个人图片或麦克风。输入/答案均为预先公开测试内容，可有意保留在报告；不记录OAuth code、token、邮箱、完整headers或任意服务端错误正文。

任何请求网络/权限/额度异常停止整轮，无自动重试；取消也可能已消耗套餐额度，失败和取消保留在分母中。仅同一次用户启动的39次批次授权有效；不定时或后台自动重复。关闭测试窗口必须停止且清理本次内存登录。

## 时间如何解释

- client call总耗时：调用方开始await至返回/失败，包括actor排队、请求体及token准备；不含UI渲染、STT/TTS。
- dispatch→headers：token准备后至收到HTTP响应头。
- dispatch→firstByte：首个响应字节；不是首个可说文本。
- dispatch→firstTextDelta：首个非空白文字delta；推理事件/空白不计入，只有最终output fallback则TTFT为空。
- dispatch→completed：解析器实际接收并接受completed，不等于client已成功返回。
- dispatch→EOF：HTTP流结束；MVP目前等EOF并通过完整/非空检查才返回回答。
- dispatch→returned：生产client即将成功返回；不包含调用方actor hop、界面和首音。completed后失败/取消仍算失败。

因此不能把TTFT当作眼镜开口时间，或用替身延迟声称某模型更快。模型对语音应用的初步比较以完整返回时间和质量门槛为主；真机首音仍单独测。

## 报告及选择规则

每model/task显示尝试数、成功/失败/缺失数、中位数及min–max；TTFT显示有值样本数。每格必须精确有唯一repetition 0/1/2。重复样本、未知model/task或超39条报告拒绝。缺失/失败不删去后假装完整；n=3只属于pilot，不提供可靠P95或普适最优结论。

报告生成model-hidden-answer-review.csv；它隐藏模型名与速度，但序号可回联，不夸称严格盲审。按正确事实、语言、简短、实用、不虚构位置/工具/材料/视觉内容逐答案审阅，probe也要审。未提交全部明确通过评分时recommendation为null；自动词语命中只提供辅助。合格模型按四任务中位数的中位数等权比较，只能叫“本次网络/任务套件的小样本暂选”。原始记录保留每次请求的token usage（若服务器返回），不能据此虚构实际金额或套餐扣量。

## 开发运行入口

```
bash MVP/scripts/check-benchmark-timing.sh
python3 MVP/scripts/report-model-benchmark.py --self-test
bash MVP/scripts/build-mac-benchmark.sh
```

构建不会登录或推理。工具内置无网络的--self-check、--lifecycle-check；产物记录实际编译输入SHA256和dirty状态，不仅抄git HEAD冒认来源。正式比较仅在本人可操作官方页面时启动。结果保存在本工具工作目录的run-*下；生成报告：

```
python3 MVP/scripts/report-model-benchmark.py /absolute/path/to/run-directory
```

人工审阅后提供answer_id→true/false的JSON，通过--ratings路径再次生成报告。任何未完成的真实授权/模型比较仍明确标NOT RUN，不会填造毫秒数或模型名次。

官方依据：[SIWC模型与推理](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)、[官方延迟优化](https://developers.openai.com/api/docs/guides/latency-optimization)。文档说明不替代本项目的实测结果。
