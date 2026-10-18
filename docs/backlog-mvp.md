# MVP backlog / GitHub issue index

The fork's linked GitHub issues are the source of truth. This file indexes the scoped MVP and ten published follow-up issues. Do not expand the MVP by exposing unfinished upstream features in its main flow.

## MVP tracking issue

**Title:** Bilingual MVP: Chinese/English turn-based voice and glasses-photo Q&A

**Suggested labels:** `mvp`, `enhancement`

**Outcome:** On iPhone + US displayless Ray-Ban Meta Gen 3, manually start a conversation in Mandarin or English, request a fresh glasses photograph on demand, receive a spoken answer, and use the existing ChatGPT subscription where supported without silent paid fallback.

**Definition of done:** Implement the scoped flow; publish actual test evidence for both gates in [acceptance-mvp.md](acceptance-mvp.md); list blockers honestly. Local simulator build/run must pass before iPhone installation. Include signing/Meta registration, auth limitation and uninstall/sign-out instructions. Keep original license attribution.

**Acceptance links:** BUILD-01 through SOAK-01 in the acceptance document. Do not close solely because the source compiles or a mocked model answers.

**GitHub issue:** https://github.com/andywangyzfh/OpenVision/issues/1

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
