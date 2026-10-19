# Bilingual MVP acceptance / 双语 MVP 验收

2026-10-18 独立Review更新：当前**整体未验收**。执行入口与逐项状态以 [完整测试用例](test-plan-mvp.md)、[执行登记CSV](test-cases-mvp.csv) 和 [独立Review](test-plan-review-mvp.md) 为准。新增本地安全前置A21～A25尚待闭合；原61项PASS只保留为历史集合结果。真实联网S1单独先于手机S2，不能把它统称“缺手机所以没测”。

This is the release contract, **not a record that the checks have passed**. Record actual results against the tested Git commit in the evidence table below. A parser check, mocked test, simulator run and glasses test establish different facts and must not be substituted for one another.

## Scope

Target: Andy's iPhone and US Ray-Ban Meta Gen 3 without a display. The MVP provides manually started, turn-based Mandarin (`zh-CN`) or English (`en-US`) conversation, Apple speech recognition and system TTS, and an explicit glasses-photo question. Prefer the existing ChatGPT subscription where usable. It must not silently choose an API-key backend, paid cloud speech, a different account or the iPhone camera.

Two selectable language modes are sufficient; automatic bilingual language detection and simultaneous mixed-language speech recognition are not required. The English mode must remain usable after adding Chinese. The first version may keep some engineering settings in English. A selected language is an interaction preference, not a guarantee that the model or speech service always produces correct output.

Continuous video, always-on wake words, reliable locked-screen conversation, local model downloads, alternative model providers, face recognition, external agents/MCP, web search, calendar/reminders and persistent notes are outside this MVP. Track those in [backlog-mvp.md](backlog-mvp.md) and GitHub issues.

## Result vocabulary and evidence

- **PASS**: the described observable check ran on the recorded commit and matched the expected result.
- **FAIL**: it ran and did not match; attach a reproduction and issue.
- **BLOCKED**: a prerequisite is unavailable (Xcode/runtime/device/account/permission/SDK entitlement). Specify the prerequisite and next action.
- **NOT RUN**: not attempted. It is never equivalent to PASS.

Evidence must include command or exact manual steps, timestamp, Git SHA, OS/Xcode/runtime versions, device and SDK/firmware versions when applicable, result, and a redacted log/test-result reference. Do not record passwords, bearer/refresh tokens, OAuth codes, personal photographs or private conversation transcripts in GitHub. Public fixture phrases and synthetic images below are safe test material.

Levels: **A** = deterministic automated test with fixtures/mocks; **S** = simulator/app integration; **D** = physical iPhone + glasses; **L** = real account/network. Static review and Swift parsing are useful supporting evidence but do not satisfy S/D/L.

## Gate 1: local verification before iPhone installation

| ID | Level | Test and acceptance condition |
| --- | --- | --- |
| BUILD-01 | A | Generate/resolve the actual MVP project from a clean checkout and build its iOS simulator target. Record the Xcode and simulator destination. Zero compile/link errors. Dependency versions must be pinned/reproducible; dependency download failures are BLOCKED, not compiler successes. |
| BUILD-02 | A | Run the MVP unit tests on the built target. All pass, zero unexpected failures. Report the suite names and counts, including upstream regression checks relevant to auth, secrets and request formatting. |
| BUILD-03 | S | Launch the MVP in simulator. Language picker, conversation controls, auth state and photo action render; excluded features are not offered as working MVP actions. Missing glasses produce an explanatory disconnected state. |
| LANG-01 | A/S | Select 中文, relaunch, then select English and relaunch. `zh-CN` / `en-US` recognition and matching system-voice selection follow the setting; persistence and old-settings migration do not crash. Unsupported recognition language or missing voice gives actionable feedback instead of pretending to listen/speak. |
| LANG-02 | A | Parser/turn logic accepts short Mandarin inputs `你好`, `继续`, `好`, `是` as nonempty utterances; it does not rely on English word count or `count > 3`. Empty, punctuation-only and whitespace-only input do not make model requests. One finalized utterance makes at most one request. |
| LANG-03 | A | The active model instruction requests concise spoken answers in the selected language. Chinese sentence endings `。！？` and English `.?!` remain intelligible when speech is chunked/capped; no split UTF-8 or lost Chinese final sentence. |
| LANG-04 | A | Explicit photo requests `看看这个`, `拍照看看`, `拍张照片告诉我这是什么`, `Take a photo and tell me what this is`, and `What do you see?` enter the photo path. Ordinary `我今天想聊摄影` / `Let's talk about photography` stay text-only. Explicit Stop/Cancel controls cancel work; continuous-video commands cannot start a stream in this MVP. |
| TURN-01 | A/S | Exercise idle → listening → thinking → speaking → idle, success, cancel and error paths. Capture and model tasks are serialized; rapid repeated taps cannot send duplicate turns. Delayed results from a canceled/previous turn cannot update the current turn or speak. |
| TURN-02 | A/S | Recognition is gated during synthesized speech. Inject a transcript equivalent to the app's own response while speaking; zero new model or camera calls. Tapping Stop halts TTS and any pending request and leaves a recoverable state. Voice barge-in is not required in MVP. |
| PHOTO-01 | A | Fake glasses return image A for request 1 and image B for request 2. Each question receives exactly its own newly captured photo, never `lastPhotoData` from an older turn. Cancel/timeout/reconnect followed by a late callback cannot attach a stale image to the next request. |
| PHOTO-02 | A/S | Missing connection, denied camera permission, capture failure, empty/corrupt photo and timeout each produce a useful error; no visual model request is sent without a valid current photo. No fallback to iPhone camera or fabricated scene description. A text retry must not claim to have seen the scene. |
| PHOTO-03 | A | Success, failure, cancellation and timeout all release the temporary camera stream/device session. A model/network error after capture also leaves camera off. The stream must not remain active while the user listens to the answer. |
| AUTH-01 | A | PKCE/state/callback-path tests reject wrong or missing state and provider denial. Token parsing/refresh/revocation fixtures are covered. Credentials are stored in Keychain, not UserDefaults or committed config. Sign-out removes locally held subscription credentials. |
| AUTH-02 | A/S | Not signed in, expired/revoked login, no available model and subscription quota rejection all stop cleanly with a visible reason. No API-key provider, cloud TTS or paid fallback is invoked. The MVP displays the actual supported subscription route and its limitations. |
| NET-01 | A | Mock offline/timeout/401/403/429/5xx and malformed/empty streaming responses. The UI leaves its busy state, explains failure, and supports an explicit retry. There is no unbounded retry loop or automatic replay of a photo request. |
| PRIV-01 | A/review | Search the MVP's reachable logging/storage paths. No access/refresh token, OAuth code, authorization header, raw photo, full user transcript or full model reply is logged or retained by default. Redacted operational state and synthetic test fixtures are acceptable. New secrets/config are gitignored. |
| LIFE-01 | A/S | Cancel, navigate away, language switch and app suspension invalidate the active turn and release recognition/camera resources. A late callback after suspension cannot resume recording or speech. On return, the app is usable and requires an explicit new start if the old turn was canceled. |

**扩展本地S0还必须完成新清单A21/A22及Review要求的A23～A25处理；上表原17项通过本身不再表示扩展S0已闭合。** 原本地集合要求BUILD-01/02/03及所列A/S条件通过。 A successful `swiftc -parse`, portable policy harness or source review alone is partial evidence. Missing Xcode or inability to run the application leaves the local gate BLOCKED. Do not describe that state as “full local testing complete” or proceed with iPhone installation as though it passed.

## Gate 2: installation and device acceptance

Prerequisites: local gate passed; a connected/unlocked iPhone with supported iOS and Developer Mode; Apple signing configured; Meta AI app, Meta developer registration/permissions and the user's glasses available. Record the exact firmware/DAT versions. Account login and permissions are performed by the user through the provider/system UI. Never copy an existing Codex CLI token into the app.

| ID | Level | Test and acceptance condition |
| --- | --- | --- |
| DEVICE-01 | D | Install the tested build, open it, register the glasses and confirm connected/disconnected UI. Ordinary Meta AI operation remains available after ending the app session. Record signing expiry/renewal instructions for a free Apple account. |
| AUDIO-01 | D | Verify and record actual input/output routes, first iPhone-only then glasses. Speak with the phone away from the mouth to distinguish glasses input from phone input. Audio route limitations are visible; there is no claim of glasses-mic success based only on hearing the reply. |
| CN-01 | D/L | In quiet indoor conditions complete 10 Mandarin turns from the fixed corpus below, including `你好`, `继续` and one follow-up. At least 9/10 preserve the intended question, all accepted turns receive a Mandarin spoken answer, zero crashes/duplicate turns. Failures remain visible rather than silently disappearing. |
| EN-01 | D/L | Complete 10 English turns, including a short `Yes` and a contextual follow-up; at least 9/10 preserve intent and all accepted turns speak English. Switch Chinese → English → Chinese without restarting the app and complete one turn in each mode. |
| PHOTO-04 | D/L | Point glasses at a synthetic printed test card A, ask in Mandarin, then card B and ask in English. Correct visible details from the fresh card appear in both answers. Five successive captures complete without stale-card answers. Camera activity ends after each capture before model narration. |
| PHOTO-05 | D | Deny Meta camera permission, remove glasses/disconnect during capture, and cancel while capturing. Each attempt stops cleanly; no scene answer is invented and no phone camera opens. Restore permission/reconnect and a subsequent capture works. |
| AUDIO-02 | D | After a voice turn, request a photo, then resume voice for five cycles. Test the known Bluetooth HFP/camera-session conflict: either it succeeds, or a clear recoverable error and explicit retry are offered. No permanently deaf mic, spinning state or endless reconnection. |
| SUB-01 | L | After reviewing the displayed auth-route limitations, user signs in through the provider UI. Complete one text turn and one photo question with the existing subscription and no API key. Record model/account plan, quota outcome and any impact on another Codex login; never record credentials. If the route is unsupported/unavailable this check is BLOCKED and subscription compatibility remains unverified. |
| SUB-02 | D/L | Cancel the browser login, sign out, and simulate or exercise expired/revoked/quota-exhausted login. The app reports the state, clears credentials on sign-out, and never starts paid API traffic. Re-login/retry is possible. |
| RES-01 | D/L | During listening/capture/request/TTS independently interrupt network, take an audio interruption, and background/lock the phone. Resources stop safely, errors are understandable, and foreground retry works. Continuing while locked is not a required feature. |
| PRIV-02 | D | Inspect redacted device logs/storage after public-fixture runs: no tokens or raw user payloads logged. User can clear the current session and sign out. Photos are not saved to Photos or persistent app history without an explicit feature/consent. |
| SOAK-01 | D/L | Run a 20-minute foreground session alternating the two languages and at least five photo turns. Zero crash/hang, zero unsolicited capture, zero self-triggered turn. Record capture and end-to-end response latencies, battery drop and thermal state; do not assert a universal latency/battery guarantee from one run. |

**Device acceptance requires every required D/L row to PASS.** A blocked subscription route must be reported as such; a separate API-key demonstration does not satisfy SUB-01. Release claims must list any failed/blocked criteria. The MVP can be delivered as development work with an honest pending validation report, but cannot be called fully accepted until both gates pass.

## Fixed speech and camera fixtures

Use 10 turns per language, with the tester speaking naturally once. Record only intent/pass counts by default:

1. `你好` / `Hello`.
2. `请用一句话介绍你自己` / `Introduce yourself in one sentence`.
3. `一加二等于几` / `What is one plus two?`
4. `请记住这个会话里的数字是四十二` / `For this conversation, remember the number forty-two`.
5. `刚才的数字是多少` / `What was the number?`
6. `继续` / `Continue` (after a suitable unfinished explanation).
7. `好` / `Yes` (after a suitable question).
8. `用中文解释一下 Bluetooth` / `Explain Bluetooth briefly`.
9. `给我一个做饭的小建议` / `Give me one cooking tip`.
10. `谢谢，结束这个话题` / `Thanks, let's end this topic`.

Print two high-contrast public fixtures: A = “BLUE SQUARE / 蓝色方块 / 27” with a blue square; B = “RED TRIANGLE / 红色三角形 / 64” with a red triangle. Ask color/shape/number, change the card between captures, and deliberately repeat after a failed capture. A fixture can validate freshness and basic perception, not general OCR quality or safety-critical scene understanding.

## Evidence ledger

Append results here or link to a redacted report in the fork. Initial status below is deliberately unclaimed.

| Run | Git SHA / environment | Criteria | Result | Evidence / next action |
| --- | --- | --- | --- | --- |
| Planning baseline | Not a test execution | All | NOT RUN | This document defines acceptance; fill from actual runs. |
| Local portable integration | `bafbb67`, macOS CLT Swift 6.3.3 | Core policies, auth contracts, VM cancellation/photo-isolation scenarios | PASS (supporting evidence) | 120 core assertions, 42 subscription assertions, 17 actual-VM scenarios. Hardware/account/transport are fixtures for the VM suite; no iOS SDK used. |
| Initial remote CI | `ca3d4ed`, Xcode 26.6 / Swift 6.3.3, iPhone 17 Pro simulator iOS 26.4.1 | Actual simulator app build and fixture launch, package XCTest | PASS (remote only) | [Run 39105084021](https://github.com/andywangyzfh/OpenVision/actions/runs/39105084021); 17 Core + 7 Subscription + 3 UI test cases; predates latest refresh/flow additions. |
| Previous remote CI | `bafbb67`, Xcode 26.6 / Swift 6.3.3, iPhone 17 Pro simulator iOS 26.4.1 | Current app compile/launch, Core/Subscription XCTest, 3 UI fixtures | PASS (remote only) | [Run 39105717171](https://github.com/andywangyzfh/OpenVision/actions/runs/39105717171), [xcresult and logs](https://github.com/andywangyzfh/OpenVision/actions/runs/39105717171/artifacts/12128452712); 17 + 7 + 3 test cases, plus all 120/42/17 portable checks. |
| Initial follow-up | `b6a3809`, local Xcode 27.1 and remote CI | Production platform / startup / UI | FAIL | Initial unsigned Keychain entitlement failures and SDK startup crash; ineffective synthetic Home event in local UI. See validation record for fixes. |
| Clean local regression | `c6e0c1b`, Xcode 27.1 / iOS Simulator 27.1 | Full local packages/platform/UI and portable checks | PASS (before privacy hardening) | 17 + 7 + 29 + 7 XCTest; all 120/42/53/28/13/61 portable checks. Remote run cancelled on newer commit. |
| Historical local subset | `b49c1db73780c18befc67cb4f6db5c84596874e0`, macOS 26.6.2, Xcode 27.1, iPhone Duo OpenVision MVP / iOS 27.1 | All Gate 1 BUILD/A/S/review rows | **原集合PASS；扩展S0待补测** | 61 XCTest (17 Core + 8 Subscription + 29 platform + 7 UI), 0 failures/skips; portable 120/43/53/28/13/61. Clean-source build and complete execution; detailed per-ID mapping, warnings and artifact location in [validation-mvp.md](validation-mvp.md). |
| Final remote CI | `b49c1db`, Xcode 26.6 | Independent CI | PASS (automated only) | [Run 39113878097](https://github.com/andywangyzfh/OpenVision/actions/runs/39113878097); does not replace local evidence. |
| Physical iPhone + glasses/account | No installation or live account calls yet | Gate 2, all D/L criteria | NOT RUN | User requested phone-independent local testing first. Real audio/camera/subscription, signing, interruption and soak still required. |

Suggested per-failure entry: `ID`, steps, expected/actual, reproducibility, environment, redacted artifact, linked GitHub issue, next action. Do not mark an entire group PASS if individual required checks were omitted.
