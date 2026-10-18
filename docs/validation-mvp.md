# Validation record / 实测记录

Status: **development, local iOS gate BLOCKED, no iPhone installation yet**.

Environment: 2026-10-17, macOS, Swift 6.3.3 Command Line Tools; no full Xcode or installed iOS Simulator. The disk had approximately 15 GB available during the environment check. No real ChatGPT authorization, model inference, microphone, camera or device-install command has been executed.

| Check | Actual result | Limits |
| --- | --- | --- |
| OpenVisionCore production checks | PASS, 120 assertions | Pure language/parser/permission policy/turn lifecycle only |
| SubscriptionCore production checks | PASS, 35 assertions | Offline OAuth/JWT/request/SSE fixtures; no real account |
| Shared account store/client/listener Swift 6 typecheck | PASS with minimal macOS UI stub | UIKit account class still needs iOS compiler |
| Swift app source parsing | PASS | Parsing cannot detect iOS SDK/type/link errors |
| Info.plist + bilingual permission strings | PASS syntax | Does not prove system permission behavior |
| XcodeGen project generation | PASS | Does not compile the generated app |
| Local iOS build, XCTest, simulator UI tests | BLOCKED | `xcodebuild` requires full Xcode; CLT has no iOS SDK/XCTest |
| Camera fresh-image/error/cancel integration | NOT RUN | Requires iOS integration harness and physical DAT validation |
| Actual Mandarin/English speech/audio routing | NOT RUN | Requires iPhone + glasses |
| Actual ChatGPT plan text/image inference | NOT RUN | User authorization required after local gate |
| iPhone installation | NOT RUN | Must follow local gate, signing and physical connection |

The counts above refer to production-module executable checks, not XCTest test-case counts. Three simulator UI fixture tests are authored, but not run locally. See [acceptance-mvp.md](acceptance-mvp.md) for the complete release criteria; unchecked rows remain required.

Re-run `bash MVP/scripts/check-local.sh` and `bash MVP/scripts/check-ios.sh` after installing full Xcode and an iOS Simulator runtime. The scripts save redacted fixture results in `.test-results/` (gitignored). Attach the tested commit SHA, Xcode version and result bundle to the acceptance issue; do not upload personal photos or tokens. Remote CI results must be labeled remote and cannot replace the requested local gate.
