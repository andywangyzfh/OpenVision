import Foundation

/// SSE framing and Responses terminal-state validation, independent of URLSession.
public struct ResponseStream {
    private var dataLines: [String] = []
    private var text = ""
    private var completed = false
    private var characters = 0
    private var rawLine = Data()
    public init() {}

    /// AsyncBytes.lines drops blank lines. Read bytes directly so SSE event boundaries survive.
    public mutating func consume(byte: UInt8) throws {
        if byte == 10 {
            if rawLine.last == 13 { rawLine.removeLast() }
            guard let line = String(data: rawLine, encoding: .utf8) else { throw PlanError.malformedResponse }
            rawLine.removeAll(keepingCapacity: true)
            try consume(line: line)
        } else {
            rawLine.append(byte)
            guard rawLine.count < 4_000_000 else { throw PlanError.service("reply_too_large") }
        }
    }

    public mutating func consume(line: String) throws {
        characters += line.utf8.count
        guard characters < 4_000_000 else { throw PlanError.service("reply_too_large") }
        if line.isEmpty { try dispatch(); return }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            dataLines.append(value)
        }
    }

    private mutating func dispatch() throws {
        guard !dataLines.isEmpty else { return }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        if payload == "[DONE]" { return }
        guard let event = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let type = event["type"] as? String else { throw PlanError.malformedResponse }
        switch type {
        case "response.output_text.delta":
            guard !completed, let delta = event["delta"] as? String else { throw PlanError.malformedResponse }
            text += delta
        case "response.completed":
            guard !completed else { throw PlanError.malformedResponse }
            let response = event["response"] as? [String: Any]
            if let status = response?["status"] as? String, status != "completed" { throw PlanError.incompleteStream }
            if text.isEmpty, let output = response?["output"] as? [[String: Any]] {
                text = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                    .filter { $0["type"] as? String == "output_text" }
                    .compactMap { $0["text"] as? String }.joined()
            }
            completed = true
        case "response.failed", "error":
            let response = event["response"] as? [String: Any]
            let error = (response?["error"] ?? event["error"]) as? [String: Any]
            // Display a stable code, never arbitrary server text that could include personal data.
            throw PlanError.service(error?["code"] as? String ?? event["code"] as? String ?? "request_failed")
        case "response.incomplete": throw PlanError.incompleteStream
        default: break
        }
    }

    public mutating func finish() throws -> String {
        if !rawLine.isEmpty {
            guard let line = String(data: rawLine, encoding: .utf8) else { throw PlanError.malformedResponse }
            rawLine.removeAll()
            try consume(line: line)
        }
        try dispatch()
        guard completed else { throw PlanError.incompleteStream }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PlanError.service("empty_reply") }
        return text
    }
}
