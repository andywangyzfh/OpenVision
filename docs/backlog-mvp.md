# MVP backlog / GitHub issue index

The fork's linked GitHub issues are the source of truth. This file indexes the scoped MVP, ten deferred feature issues, and findings from local validation. Do not expand the MVP by exposing unfinished upstream features in its main flow.

## MVP tracking issue

**Title:** Bilingual MVP: Chinese/English turn-based voice and glasses-photo Q&A

**Suggested labels:** `mvp`, `enhancement`

**Outcome:** On iPhone + US displayless Ray-Ban Meta Gen 3, explicitly enable foreground glasses double-tap standby, start/stop Mandarin or English GPT voice from the temple gesture, and request a fresh glasses photograph only after per-photo App confirmation, receive a spoken answer, and use the existing ChatGPT subscription where supported without silent paid fallback.

**Definition of done:** Implement the scoped flow; publish actual test evidence for both gates in [acceptance-mvp.md](acceptance-mvp.md); list blockers honestly. Local simulator build/run must pass before iPhone installation. Include signing/Meta registration, auth limitation and uninstall/sign-out instructions. Keep original license attribution.

**Acceptance links:** BUILD-01 through SOAK-01 in the acceptance document. Do not close solely because the source compiles or a mocked model answers.

**GitHub issue:** https://github.com/andywangyzfh/OpenVision/issues/1

## Local validation follow-up

[Issue #13 — Investigate AVAudioSession main-thread warnings before device soak](https://github.com/andywangyzfh/OpenVision/issues/13): the earlier local baseline passed, but Xcode reports synchronous audio-session performance warnings. Measure responsiveness and HFP/photo transitions on the real device before AUDIO-02 / RES-01 / SOAK-01 sign-off; preserve cancellation and route ownership if scheduling changes are required. This is separate from adding new features.

新增独立Review阻塞项：[凭据删除失败安全处理 #14](https://github.com/andywangyzfh/OpenVision/issues/14)，以及[完整授权协调器/身份传输边界补测 #15](https://github.com/andywangyzfh/OpenVision/issues/15)。它们属于MVP质量收口，不是可自动豁免的后续功能。完整状态见 [测试清单](test-plan-mvp.md)。

## Current MVP priorities and follow-up

1. [#20 核心：镜腿双击GPT语音](https://github.com/andywangyzfh/OpenVision/issues/20)：默认关闭、显式前台待命，captouch only；真实Inputs权限、固件、HFP和按手势完成中英问答仍需实测。
2. [#19 P0：防意外启动相机](https://github.com/andywangyzfh/OpenVision/issues/19)：每次确认、一次性授权、撤销/重放/迟到事件、会话清理互斥；真实摄像头指示灯与原生拍摄行为仍需观察。
3. 按需识图保留在同版，不降级移除；优先级低于语音。当前图A/B与普通轮不重发图须共同验收。
4. [#22 排队开始在Stop后不得重新开麦](https://github.com/andywangyzfh/OpenVision/issues/22)：同步捕获激活世代，本地Flow109正反例通过；新版本未装到手机。
5. [#17 播报完成/停止状态](https://github.com/andywangyzfh/OpenVision/issues/17)、[#18 有上限的本机模型比较](https://github.com/andywangyzfh/OpenVision/issues/18)、[#21 键盘布局警告](https://github.com/andywangyzfh/OpenVision/issues/21)分别保留软件回归、真实模型和设备限制。

完整逐轮结果见[本机回归](local-benchmark-mvp.md)及[执行索引](test-inventory-local-followup-20261019.csv)。历史通过不能覆盖新增范围失败；没有运行真实模型就没有速度排名。当前本地软件已获独立Review批准；平台57、最终UI25、Core17、Subscription14为分组运行覆盖，历史失败不删。#21同时保留native Done无效激活位置，固定footer返回入口通过UI验收，未声称原工具栏已修复。手机仍为旧b1c2ea5。产品主issue开放、PR为draft。

## Deferred issues

### BACKLOG-01 — Harden ChatGPT subscription eligibility and live-account onboarding

**Labels:** `auth`, `research`, `post-mvp`

**Problem:** This fork's MVP implements the documented Sign in with ChatGPT flow in `MVP/App/Account` and `MVP/Subscription`; it does not reuse the upstream Codex CLI identity/backend. Actual account eligibility, available models and provider errors still need live validation. Do not describe implemented core authorization as a deferred feature.

**Work:** Extend onboarding with clear eligible-plan, consent, quota, unsupported-region/account and empty-model states. Maintain official-document links for registration, redirect, storage and allowed modalities; exercise authorization changes against a live account without copying credentials from another app. Preserve the MVP's no-paid-fallback rule.

**Done when:** The live eligibility matrix and provider documentation are linked; onboarding explains real denial/expiry/revoke/quota outcomes; text+photo work on an eligible real account; and paid fallbacks require a separate user choice. Required core auth/security checks remain in the MVP acceptance gate. If live validation is unavailable, mark it BLOCKED rather than bypassing authorization.

**GitHub issue:** https://github.com/andywangyzfh/OpenVision/issues/2

### BACKLOG-02 — Reliable locked-screen/background conversation

**Labels:** `audio`, `ios`, `post-mvp`

**Work:** Measure actual iOS background permissions/lifecycle behavior; define mic/camera suspension and recovery policy; test lock/unlock and audio interruptions. Do not infer this from background-audio entitlement alone.

**Done when:** A documented physical-device matrix passes repeated lock/unlock/network/call tests, with visible mic status and predictable Stop behavior. MVP only promises safe suspension and foreground retry.

**GitHub issue:** https://github.com/andywangyzfh/OpenVision/issues/3

### BACKLOG-03 — Chinese/English wake phrase and voice interruption

**Labels:** `voice`, `post-mvp`

**Work:** Add opt-in wake phrases and deliberate barge-in without mistaking TTS echo for a user command. Native “Hey Meta” interception is not assumed.

**Done when:** Both-language phrase corpus and negative/echo corpus have measured results; no unintended capture/model call in a 20-minute speech playback test; reliable physical-device Stop and interruption behavior.

**GitHub issue:** https://github.com/andywangyzfh/OpenVision/issues/4

### BACKLOG-04 — Continuous real-time voice and camera

**Labels:** `camera`, `realtime`, `post-mvp`

**Work:** Evaluate supported DAT audio/video paths and the HFP conflict; expose explicit streaming/recording state, limits and cost consent. Keep on-demand capture as an available simpler mode.

**Done when:** Real device tests establish bounded camera lifetime, no route deadlocks, predictable thermal/battery behavior, explicit stream stop, reconnect policy and separate API billing consent where needed.

**GitHub issue:** https://github.com/andywangyzfh/OpenVision/issues/5

### BACKLOG-05 — Additional providers and optional local MLX/Apple models

**Labels:** `models`, `post-mvp`

**Work:** Restore individual upstream providers only after measuring Chinese STT/TTS/vision quality, device compatibility, downloads and memory cost. Configure paid credentials independently; no automatic switch on subscription failure.

**Done when:** Each provider has a capability/cost table, removal flow for downloads/secrets, and its own acceptance evidence. Local model support does not force heavy downloads into the MVP.

**GitHub issue:** https://github.com/andywangyzfh/OpenVision/issues/6

### BACKLOG-06 — Save a conversation or photo summary to notes/Obsidian

**Labels:** `notes`, `privacy`, `post-mvp`

**Work:** Add an explicit “save this” action, destination selection, preview and deletion. Design the phone-to-Mac/vault handoff separately; do not infer vault write consent from conversation use.

**Done when:** Nothing is saved by default; a preview shows content/destination; duplicate requests are idempotent; user can delete saved content and see failures. No hidden conversation/photo retention.

**GitHub issue:** https://github.com/andywangyzfh/OpenVision/issues/7

### BACKLOG-07 — External tools, MCP and agent actions

**Labels:** `agents`, `tools`, `post-mvp`

**Work:** Add narrowly scoped tools with explicit permissions and previews for consequential actions. Keep tool services/accounts separate from model subscription auth.

**Done when:** Tool schemas, authorization boundaries, error/retry behavior and confirmation UX are tested; tool text cannot expand authority or cause unintended messages/purchases. No agent/tool execution in MVP.

**GitHub issue:** https://github.com/andywangyzfh/OpenVision/issues/8

### BACKLOG-08 — Complete Chinese/English UI localization and language detection

**Labels:** `localization`, `ux`, `post-mvp`

**Work:** Localize remaining settings/onboarding/accessibility text, support dynamic type, and evaluate optional automatic language detection for mixed speech. Keep explicit language selection available.

**Done when:** Both languages pass UI/layout/accessibility checks, switching preserves safe state, and language detection is measured on mixed-language examples. Model names and proper nouns remain intelligible.

**GitHub issue:** https://github.com/andywangyzfh/OpenVision/issues/9

### BACKLOG-09 — Translation, OCR and reusable scene tasks

**Labels:** `vision`, `post-mvp`

**Work:** Add purpose-built prompts for menus/labels/documents and optional translation. Separate photographed evidence from guesses; indicate unreadable text instead of inventing OCR.

**Done when:** Public Chinese/English image fixtures measure readability and errors, fresh-photo guarantees remain intact, and all workflows retain camera-off-after-capture behavior.

**GitHub issue:** https://github.com/andywangyzfh/OpenVision/issues/10

### BACKLOG-10 — Face recognition, persistent memory and personal data controls

**Labels:** `privacy`, `post-mvp`

**Work:** Evaluate a separate opt-in design for retained faces, photos or long-term memory. These upstream capabilities remain outside the MVP.

**Done when:** User understands storage location, retention, export/delete and any cloud transfer; disabled mode stores nothing; removal and reset are verified. Do not enable upstream retention by default.

**GitHub issue:** https://github.com/andywangyzfh/OpenVision/issues/11
