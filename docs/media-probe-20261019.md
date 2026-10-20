# Locked-screen media event probe — 2026-10-19

Status: build 3 installed; first user trial reported no response. Device records received 9 pause commands (7 active, 2 inactive_or_background), but audible feedback and physical lock conditions remain unresolved. This is not locked-screen GPT acceptance.

## Approach

Independently implemented Apple Bluetooth media commands; no Chachan backend, app integration or copied Avenkin BSL source. The user wants a glasses touch to start GPT while the phone stays locked in a pocket. An explicit foreground arm is still required for this experiment; force-quit cold launch is not promised.

The DEBUG `--mvp-media-probe` screen is isolated from normal conversation lifecycle. It does not configure Wearables, restore an account, or wire any speech/model action. Idle account/preview VM/Speech objects are still constructed; this is not a claim that those types are absent. The driver uses output-only playback, including a continuous zero-volume loop and short diagnostic tones. It occupies media controls and yields on interruption/route loss; no background coexistence with music is promised. Media events do not authenticate their source as glasses.

## Evidence and review

- Baseline repository HEAD: 2076bf9 (MVP equivalent to e8a7267); build 3 adds the six files/changes in build3-manifest.json.
- iPhone 15 Pro Max connected; installed version before test was 0.1.0(2).
- Signed build 0.1.0(3), bundle com.andywang.openvision.mvp: build command exit 0; installation and diagnostic launch exit 0.
- 18 actual service/policy checks PASS with injected playback effects. These do not simulate real Bluetooth delivery.
- Independent reviewer: APPROVE_DIAGNOSTIC_EVENT_PROBE_INSTALL_ONLY after source and binary hashes matched. No camera/microphone/model execution path found from the diagnostic entry.
- Initial device-exported JSON confirms build 3 diagnostic startup, unarmed and zero media events. This alone proves no gesture success.
- Final incremental build retains one AppIntents metadata warning (no AppIntents dependency). The initial full build log is also retained; warnings are not erased.
- Events are timestamped synchronously on receipt, with monotonic time, sequence, probe session UUID and cached foreground state. inactive_or_background does not itself prove the physical phone was locked. Match with the user's lock action and observation.
- Export errors remain visible, records remain in memory and can be exported after unlock. Static scope labels are not measured camera/microphone call counters.

## Acceptance matrix

| ID | Case | Status |
| --- | --- | --- |
| M01 | Default off; enabling does not arm | PASS injected service |
| M02 | Raw command receipt; diagnostic callback cannot activate voice | PASS injected service |
| M03 | Callback receipt time and cached foreground reflect actual service receipt | PASS injected service |
| M04 | Stop/disable/remapping/rearm invalidate old events and permits | PASS injected service |
| M05 | Route loss/interruption/other audio release claim; cleanup barriers | PASS injected service |
| M06 | Signed iPhone build/install/diagnostic startup identity | PASS device tools + exported initial JSON |
| M07 | User foreground touch produces event/cue, camera LED stays off | PENDING physical user observation and device JSON |
| M08 | Lock 30 seconds, touch produces event/cue, camera LED stays off | PENDING physical user observation and device JSON |
| M09 | Lock 2/5/30 minutes, repeated touches, no missed/duplicate activation | NOT RUN |
| M10 | Music, incoming call, disconnect/reconnect, stop, force quit | NOT RUN physical |
| M11 | Lock-screen short microphone capture with actual glasses HFP | NOT IMPLEMENTED in probe |
| M12 | Lock-screen Chinese/English GPT response and separated latency stages | NOT IMPLEMENTED in probe |
| M13 | Locked credential refresh/storage failure and explicit recovery | NOT RUN; WhenUnlocked protection unchanged |
| M14 | On-demand camera remains separately confirmed; no voice-triggered camera | Existing foreground policy unchanged; new full integration not accepted |

Normal conversation still requires foreground. The diagnostic probe does not connect its optional voice permits to the VM. Do not aggregate these 18 checks with historical XCTest counts or claim product acceptance.

Evidence directory: outputs/OpenVision-MVP-validation/media-probe-20261019 (outside repository).

## First physical trial — unresolved feedback

User reported "没反应". Export `device-events-no-response.json` contains arm_finished with no failure, 9 pause receipts, and an explicit stopped event. Seven receipts were active and two inactive_or_background; the latter were only seconds after scene changes. No 30-second locked wait is established. Source identity of generic media events cannot be certified by the API. User clarification is pending about cue audibility, whether GPT was expected, and camera LED observation. Do not mark M07/M08 PASS or claim locked GPT success from these records.
