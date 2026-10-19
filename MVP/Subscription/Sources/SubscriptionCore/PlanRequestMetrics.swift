import Foundation

/// Client transport milestones, measured from dispatch after the token supplier returns.
/// These exclude token preparation, caller scheduling, UI rendering and speech playback.
public enum PlanRequestMilestone: String, Codable, Sendable {
    case dispatched, headers, firstByte, firstTextDelta, completed, eof, returned, failed
}

/// Only aggregate token counts are exposed; no response content or identity is captured.
public struct PlanTokenUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?
    public let cachedInputTokens: Int?
    public let reasoningOutputTokens: Int?

    init(_ value: [String: Any]) {
        func count(_ raw: Any?) -> Int? {
            guard let number = raw as? Int, number >= 0 else { return nil }
            return number
        }
        inputTokens = count(value["input_tokens"])
        outputTokens = count(value["output_tokens"])
        totalTokens = count(value["total_tokens"])
        cachedInputTokens = count((value["input_tokens_details"] as? [String: Any])?["cached_tokens"])
        reasoningOutputTokens = count((value["output_tokens_details"] as? [String: Any])?["reasoning_tokens"])
    }
}

public struct PlanRequestObservation: Codable, Equatable, Sendable {
    public let milestone: PlanRequestMilestone
    public let elapsedNanoseconds: UInt64
    public let httpStatus: Int?
    public let usage: PlanTokenUsage?

    public init(milestone: PlanRequestMilestone, elapsedNanoseconds: UInt64,
                httpStatus: Int? = nil, usage: PlanTokenUsage? = nil) {
        self.milestone = milestone
        self.elapsedNanoseconds = elapsedNanoseconds
        self.httpStatus = httpStatus
        self.usage = usage
    }
}

/// Called synchronously on the request path: collect metadata quickly without blocking.
public typealias PlanRequestObserver = @Sendable (PlanRequestObservation) -> Void

/// Metadata from accepted events, never raw deltas, JSON or arbitrary server error strings.
public enum PlanStreamObservation: Sendable {
    case textDelta(hasNonWhitespaceText: Bool)
    case completed(usage: PlanTokenUsage?)
}
