import Foundation

public enum VoiceIntent: Equatable, Sendable {
    case empty
    case stop
    case cancel
    case photo(question: String)
    case conversation(text: String)
}

/// Parse complete user utterances, never background partial transcripts or the assistant's TTS.
/// Camera use is opt-in: ordinary questions, including "what is this?", do not capture a photo.
public struct CommandParser: Sendable {
    public init() {}

    public func parse(_ utterance: String) -> VoiceIntent {
        let text = Self.trim(utterance)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return .empty }
        let normalized = Self.normalize(text)
        let stops: Set<String> = ["stop", "stop speaking", "stop talking", "be quiet", "please stop", "停止", "停止说话", "别说了", "停", "暂停", "请停止"]
        let cancels: Set<String> = ["cancel", "cancel that", "never mind", "nevermind", "取消", "取消吧", "算了", "不用了"]
        if stops.contains(normalized) { return .stop }
        if cancels.contains(normalized) { return .cancel }

        // Longest phrases first so "拍张照片" does not leave a spurious "片" question.
        let chinesePrefixes = ["请看看这个", "帮我看看这个", "看看这个", "请看一下这个", "看一下这个", "请拍张照片", "帮我拍张照片", "拍张照片", "拍一张照片", "拍照问答", "拍照看看", "请拍照", "帮我拍照", "拍照"]
        for prefix in chinesePrefixes where text.hasPrefix(prefix) {
            let suffix = String(text.dropFirst(prefix.count))
            // Avoid treating noun phrases such as "拍照功能怎么用" as a capture request.
            if suffix.isEmpty || Self.isPhotoQuestionSuffix(suffix) {
                return .photo(question: Self.trim(suffix))
            }
        }

        let englishPrefixes = ["please take a photo", "please take a picture", "take a photo", "take a picture", "look at this", "look at this photo", "what am i looking at", "what do you see"]
            .sorted { $0.count > $1.count }
        let lower = text.lowercased()
        for prefix in englishPrefixes where lower.hasPrefix(prefix) {
            let suffix = String(text.dropFirst(prefix.count))
            // ASCII word boundary: "photography" must not match "photo".
            guard suffix.isEmpty || suffix.first?.isLetter == false && suffix.first?.isNumber == false else { continue }
            var question = Self.trim(suffix)
            // Remove connecting "and" but never remove words such as "android".
            if question.lowercased().hasPrefix("and ") { question = Self.trim(String(question.dropFirst(4))) }
            return .photo(question: question)
        }
        return .conversation(text: text)
    }

    private static func isPhotoQuestionSuffix(_ suffix: String) -> Bool {
        guard let first = suffix.first else { return true }
        if first.isWhitespace || first.isPunctuation { return true }
        // Mandarin has no word separators. Restrict the adjacent clause to requests, not nouns.
        return ["帮我", "告诉我", "解释", "翻译", "读一下", "读出", "描述", "然后", "这是什么", "是什么", "是不是", "有没有", "能不能", "怎么"].contains { suffix.hasPrefix($0) }
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
