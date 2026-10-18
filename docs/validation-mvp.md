# Validation record / 实测记录

Current follow-up, 2026-10-18: **local iOS gate BLOCKED by Xcode first-launch license/setup; no iPhone installation**. Xcode 27.1 (27A9275) is installed, but `xcodebuild -license check` reports that its license has not been accepted. The active system developer directory remains Command Line Tools. Test scripts now discover the installed Xcode without changing that global setting, then stop on unfinished first launch. The user must review and accept the license in Xcode; no automated acceptance is performed.

## Follow-up local evidence

`bash MVP/scripts/check-local.sh` passed on the existing licensed CLT Swift 6.3.3 environment after integrating the new production test boundaries:

| Executed locally | Result | Boundary |
| --- | --- | --- |
| Core behavior | PASS, 120 assertions | Actual language/parser/turn policies |
| Subscription contracts and cryptography | PASS, 42 assertions | Actual payload, JWT signature, SSE and refresh merge |
| Conversation flow | PASS, 51 scenarios | Actual VM, fake hardware/account/transport |
| HTTP transport | PASS, 28 scenarios | Actual PlanClient/URLSession with every request intercepted by ephemeral URLProtocol; no external traffic |
| Account ownership/persistence | PASS, 13 scenarios | Actual Store actor, memory persistence and controlled refresh/revoke; no user Keychain |
| OAuth callback | PASS, 61 assertions | Actual production listener/waiter, real 127.0.0.1 HTTP and synthetic codes; no external authentication |
| Swift syntax, plist and XcodeGen | PASS | Includes added platform tests; not an iOS typecheck/build |
| Git connectivity/integrity | PASS | Transient cloud-file read timeout recovered; working files preserved |

Authored but **NOT RUN** locally: 11 production camera-controller tests, 13 speech-controller tests, 2 isolated iOS Keychain tests, and 7 UI tests. The platform bundle compiles the exact production service sources with fake platform effects and no application host; the separate UI target launches the actual App. Tests cover image re-encoding/GPS removal, capture ownership/cleanup, STT/TTS callback identity, language persistence, settings, background recovery and production startup without restoring an account. They must still compile and execute before any PASS is claimed. They do not prove physical DAT/AVAudio behavior.

The follow-up extracts platform effects into thin default SDK/Apple drivers, adds injectable persistence/transport boundaries, makes a stopped or empty-final speech task recoverable, and stops active work when settings opens. It does not add new product features. Production defaults continue using the official DAT/Apple/ChatGPT paths. Old test results below belong to the older source revision and cannot validate these changes.

After the user completes first launch: use Xcode 27.1 for the local package XCTest suites and actual iOS build/platform/UI run, save the tested SHA, runtime and xcresult, and review every local criterion in [acceptance-mvp.md](acceptance-mvp.md). Physical speech, camera, real subscription authorization and iPhone installation remain NOT RUN.

## Previous baseline evidence (before this follow-up)

Latest remote evidence: [CI run 39105717171](https://github.com/andywangyzfh/OpenVision/actions/runs/39105717171), code **`bafbb67ddfd2800830db92b8b99fb18fbc1a0012`**, **PASS** on Xcode 26.6 / Swift 6.3.3, iPhone 17 Pro simulator iOS 26.4.1. The run includes the current refresh/flow changes: 120 core assertions, 42 subscription assertions, 17 actual-VM scenarios, 17 Core XCTest cases, 7 Subscription XCTest cases, and 3 UI fixture tests. Actual iOS App compilation and simulator launch succeeded. [Download the redacted test evidence and xcresult bundle](https://github.com/andywangyzfh/OpenVision/actions/runs/39105717171/artifacts/12128452712).

The earlier [ca3d4ed run](https://github.com/andywangyzfh/OpenVision/actions/runs/39105084021) also passed its iOS tests; its initial artifact uploader skipped a hidden directory, which the latest run fixed. Documentation-only follow-up commits do not change the tested application sources. **Neither remote run passes the requested local gate.**

Environment: 2026-10-17, macOS, Swift 6.3.3 Command Line Tools; no full Xcode or installed iOS Simulator. The disk had approximately 15 GB available during the environment check. No real ChatGPT authorization, model inference, microphone, camera or device-install command has been executed.

| Check | Actual result | Limits |
| --- | --- | --- |
| OpenVisionCore production checks | PASS, 120 assertions | Pure language/parser/permission policy/turn lifecycle only |
| SubscriptionCore production checks | PASS, 42 assertions | Offline OAuth/JWT/request/SSE/refresh-merge fixtures; no real account |
| Production ConversationViewModel flow checks | PASS, 17 async scenarios | Actual VM/Core/Subscription compiled with fake hardware/account/transport; cancellation, fresh A/B photo payloads, duplicates, permission waits, TTS resume, signout, language persistence |
| Shared account store/client/listener Swift 6 typecheck | PASS with minimal macOS UI stub | UIKit account class still needs iOS compiler |
| Swift app source parsing | PASS | Parsing cannot detect iOS SDK/type/link errors |
| Info.plist + bilingual permission strings | PASS syntax | Does not prove system permission behavior |
| XcodeGen project generation | PASS | Does not compile the generated app |
| Local iOS build, XCTest, simulator UI tests | BLOCKED | `xcodebuild` requires full Xcode; CLT has no iOS SDK/XCTest |
| Camera fresh-image/error/cancel integration | NOT RUN | Requires iOS integration harness and physical DAT validation |
| Actual Mandarin/English speech/audio routing | NOT RUN | Requires iPhone + glasses |
| Actual ChatGPT plan text/image inference | NOT RUN | User authorization required after local gate |
| iPhone installation | NOT RUN | Must follow local gate, signing and physical connection |

The assertion/scenario counts above refer to executable checks, not XCTest test-case counts. `check-flow.sh` compiles the actual VM source directly with Swift 6; only platform/transport services are replaced. Three simulator UI fixture tests are authored, but not run locally. See [acceptance-mvp.md](acceptance-mvp.md) for the complete release criteria; unchecked rows remain required.

Re-run `bash MVP/scripts/check-local.sh` and `bash MVP/scripts/check-ios.sh` after installing full Xcode and an iOS Simulator runtime. The scripts save redacted fixture results in `.test-results/` (gitignored). Attach the tested commit SHA, Xcode version and result bundle to the acceptance issue; do not upload personal photos or tokens. Remote CI results must be labeled remote and cannot replace the requested local gate.
