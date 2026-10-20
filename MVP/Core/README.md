# OpenVision bilingual core

Pure Swift business rules used by the minimal iPhone app. There are no Apple Speech,
Bluetooth, camera, network, token-storage, or model dependencies in this package.

## Contract

```swift
let language = ConversationLanguage.chinese // persist rawValue "zh-CN"
let locale = language.recognitionLocaleID  // pass to SFSpeechRecognizer
let intent = CommandParser().parse("看看这个，帮我翻译标签")
// .photo(question: "帮我翻译标签")
let decision = CameraAccessPolicy.decision(for: intent, permission: .authorized)
// .captureOnce
```

- Select Mandarin or US English explicitly. The language selection determines both
  ASR and TTS; a clear user utterance can change the response language without
  silently changing the recognizer locale. This is bilingual selection, not an
  unsupported promise of automatic bilingual speech recognition.
- Parse only the user's completed utterance. Never submit partial ASR results or
  the model's own TTS transcript as commands.
- Stop and cancel match complete normalized utterances. Substrings such as
  `stopwatch`, `don't stop`, and `取消订单的方法是什么` are conversational text.
- A camera request must start with an explicit supported command. Examples:
  `看看这个`, `帮我看看这个`, `看一下这个是什么`, `拍照问答：…`, `拍张照片，…`,
  `look at this`, `take a photo and …`, `what am I looking at?`.
- Mandarin does not require spaces or a minimum four-character utterance. Ordinary
  short turns (`好`, `是`, `不`) remain valid.
- Camera permission is separate from speech/microphone permissions. Permission is
  requested only for an explicit photo intent; denial never silently substitutes
  an old photo, starts a stream, or invents visual context.
- `captureOnce` describes one fresh photo. The hardware adapter may briefly need
  a DAT stream, which it must stop after obtaining that photo.

The parser is deliberately bounded and deterministic, not an LLM intent detector.
For example `这是什么？` and `what is this?` remain ordinary conversation, so users
can ask about words or prior replies without accidentally capturing a camera image.

## Automated acceptance

`swift test --package-path MVP/Core` checks:

1. Selected recognition/TTS locales and Codable persistence round-trip.
2. Clear response-language detection and selected-language fallback for ambiguous
   or mixed-language utterances.
3. Chinese/English stop/cancel commands and negative substring cases.
4. On-demand photo triggers, Mandarin suffixes, English word boundaries, and
   extraction that preserves internal question content.
5. Short Mandarin turns and empty/punctuation-only rejection.
6. No camera access for conversation, stop, cancel, or empty turns, at every
   permission state; photo requests ask permission or capture once as appropriate.
7. Cancellation, a new turn, or listening again invalidates the previous turn ID;
   a late photo/model callback cannot advance or speak over the current turn.

On a Mac with only Command Line Tools, `XCTest` may be absent. Run the portable
behavioral checks using `swift run --package-path MVP/Core CoreChecks` instead.
This executable exits on any mismatch and covers the same parser, language,
camera-policy, and turn-identity rules without claiming that iPhone UI or hardware
tests passed.

These unit tests do not validate microphone quality, Apple ASR language
availability, Bluetooth routing, DAT firmware behavior, signing, iPhone background
operation, live model authorization, or generated-answer quality. Those require
the app and physical-device acceptance checks.
