# Validation record / 实测记录

Status: **development, local iOS gate BLOCKED, no iPhone installation yet**.

Remote evidence: [CI run 39105084021](https://github.com/andywangyzfh/OpenVision/actions/runs/39105084021), code `ca3d4ed`, **PASS** on Xcode 26.6: actual iOS simulator app build/launch, 17 Core XCTest cases, 7 Subscription XCTest cases, and 3 UI fixture tests. This run predates the refresh-merge and 17-scenario flow-test additions below. Initial artifact upload skipped the hidden results directory; the CI log contains the successful test results, and the follow-up workflow fixes result-bundle upload. Remote evidence does not pass the requested local gate.

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
