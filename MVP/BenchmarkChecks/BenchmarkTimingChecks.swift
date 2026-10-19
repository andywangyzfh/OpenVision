import Darwin
import Foundation
import Dispatch
import SubscriptionCore

private struct CheckFailure: Error { let message: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw CheckFailure(message: message) }
}
private final class TickClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: UInt64 = 0
    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; ticks += 1; return ticks * 1_000_000 }
    func calls() -> UInt64 { lock.lock(); defer { lock.unlock() }; return ticks }
}
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [PlanRequestObservation] = []
    func record(_ entry: PlanRequestObservation) { lock.lock(); entries.append(entry); lock.unlock() }
    func snapshot() -> [PlanRequestObservation] { lock.lock(); defer { lock.unlock() }; return entries }
}
private let delta = #"{"type":"response.output_text.delta","delta":"fixture-sensitive-answer"}"#
private let complete = #"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":12,"output_tokens":8,"total_tokens":20,"input_tokens_details":{"cached_tokens":2},"output_tokens_details":{"reasoning_tokens":3}}}}"#
private func sse(_ events: [String]) -> Data { Data(events.map { "data: " + $0 + "\n\n" }.joined().utf8) }
private func fixture(_ reply: MockReply) -> (ChatGPTPlanClient, URLSession, Collector, TickClock) {
    MockLedger.shared.reset([reply])
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OfflineURLProtocol.self]
    let session = PlanHTTPTransport.makeSession(configuration: configuration)
    let clock = TickClock(), collector = Collector()
    let client = ChatGPTPlanClient(session: session, tokenSupplier: { "synthetic-benchmark-token" }, invalidateToken: { _ in }, nowNanoseconds: { clock.now() })
    return (client, session, collector, clock)
}
private func call(_ client: ChatGPTPlanClient, _ observer: PlanRequestObserver? = nil) async throws -> String {
    try await client.respond(model: "fixture-plan", instructions: "Public fixture instructions.", turns: [.init(role: "user", text: "Public fixture question.")], observer: observer)
}
private func milestones(_ collector: Collector) -> [PlanRequestMilestone] { collector.snapshot().map(\.milestone) }
private func failedCall(_ reply: MockReply, expected: [PlanRequestMilestone], check: @Sendable (Error) -> Bool = { _ in true }) async throws {
    let (client, session, collector, _) = fixture(reply)
    defer { session.invalidateAndCancel() }
    var caught: Error?
    do { _ = try await call(client, { collector.record($0) }) } catch { caught = error }
    try expect(caught != nil && caught.map(check) == true, "Original error was lost or failure returned success")
    try expect(milestones(collector) == expected, "Failure milestones differ: \(milestones(collector))")
    try expect(MockLedger.shared.snapshot().count == 1, "Implicit request retry")
}

@main
struct BenchmarkTimingChecks {
    static func main() async {
        let scenarios: [(String, @Sendable () async throws -> Void)] = [
            ("production client separates headers, first byte, first text, completed, EOF and return", {
                let events = [#"{"type":"response.output_text.delta","delta":""}"#, #"{"type":"response.output_text.delta","delta":"  "}"#, #"{"type":"response.reasoning_text.delta","delta":"not user-visible"}"#, delta, #"{"type":"response.output_text.delta","delta":" second"}"#, complete]
                let (client, session, collector, _) = fixture(.init(mime: nil, body: sse(events), chunkSize: 1))
                defer { session.invalidateAndCancel() }
                let answer = try await call(client, { collector.record($0) })
                try expect(answer == "  fixture-sensitive-answer second", "Timing changed the answer")
                try expect(milestones(collector) == [.dispatched, .headers, .firstByte, .firstTextDelta, .completed, .eof, .returned], "Milestones or first-delta filtering wrong")
                let observations = collector.snapshot()
                try expect(observations.map(\.elapsedNanoseconds) == [0, 1_000_000, 2_000_000, 3_000_000, 4_000_000, 5_000_000, 6_000_000], "Injected monotonic clock is not measured from dispatch")
                try expect(observations[1].httpStatus == 200, "HTTP status missing")
                let usage = observations[4].usage
                try expect(usage?.inputTokens == 12 && usage?.outputTokens == 8 && usage?.totalTokens == 20 && usage?.cachedInputTokens == 2 && usage?.reasoningOutputTokens == 3, "Token aggregate usage wrong")
                let encoded = String(decoding: try JSONEncoder().encode(observations), as: UTF8.self)
                try expect(!encoded.contains("fixture-sensitive-answer") && !encoded.contains("synthetic-benchmark-token") && !encoded.contains("Public fixture"), "Metrics retained request/response/credential content")
                try expect(MockLedger.shared.snapshot().count == 1, "Implicit retry")
            }),
            ("completed final-output fallback succeeds with TTFT absent", {
                let fallback = #"{"type":"response.completed","response":{"status":"completed","output":[{"content":[{"type":"output_text","text":"fallback answer"}]}]}}"#
                let (client, session, collector, _) = fixture(.init(body: sse([fallback])))
                defer { session.invalidateAndCancel() }
                let answer = try await call(client, { collector.record($0) })
                try expect(answer == "fallback answer", "Fallback answer lost")
                try expect(milestones(collector) == [.dispatched, .headers, .firstByte, .completed, .eof, .returned], "Fallback invented TTFT")
                try expect(collector.snapshot().first(where: { $0.milestone == .completed })?.usage == nil, "Absent usage invented")
            }),
            ("terminal event dispatched only at finish is timestamped after EOF", {
                let (client, session, collector, _) = fixture(.init(body: Data((String(decoding: sse([delta]), as: UTF8.self) + "data: " + complete).utf8)))
                defer { session.invalidateAndCancel() }
                _ = try await call(client, { collector.record($0) })
                try expect(milestones(collector) == [.dispatched, .headers, .firstByte, .firstTextDelta, .eof, .completed, .returned], "EOF finish completion ordering hidden")
            }),
            ("late structured error never records completed or returned", {
                try await failedCall(.init(body: sse([delta, #"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#])), expected: [.dispatched, .headers, .firstByte, .firstTextDelta, .failed], check: { $0 as? PlanError == .service("subscription_sharing_usage_limit_exceeded") })
            }),
            ("incomplete event never records completed", {
                try await failedCall(.init(body: sse([delta, #"{"type":"response.incomplete"}"#])), expected: [.dispatched, .headers, .firstByte, .firstTextDelta, .failed], check: { $0 as? PlanError == .incompleteStream })
            }),
            ("invalid completed status is rejected before success milestone", {
                try await failedCall(.init(body: sse([delta, #"{"type":"response.completed","response":{"status":"incomplete"}}"#])), expected: [.dispatched, .headers, .firstByte, .firstTextDelta, .failed], check: { $0 as? PlanError == .incompleteStream })
            }),
            ("EOF without completed records EOF then failure", {
                try await failedCall(.init(body: sse([delta])), expected: [.dispatched, .headers, .firstByte, .firstTextDelta, .eof, .failed], check: { $0 as? PlanError == .incompleteStream })
            }),
            ("completed without answer still fails and cannot be reported as successful return", {
                try await failedCall(.init(body: sse([complete])), expected: [.dispatched, .headers, .firstByte, .completed, .eof, .failed], check: { $0 as? PlanError == .service("empty_reply") })
            }),
            ("HTTP admission failure has headers and failure only", {
                try await failedCall(.init(status: 503), expected: [.dispatched, .headers, .failed], check: { $0 as? PlanError == .service("http_503") })
            }),
            ("cancellation after first text cannot be measured as completed success", {
                let (client, session, collector, _) = fixture(.init(body: sse([delta, complete]), chunkSize: 1))
                defer { session.invalidateAndCancel() }
                let task = Task {
                    try await call(client, { entry in
                        collector.record(entry)
                        if entry.milestone == .firstTextDelta { withUnsafeCurrentTask { $0?.cancel() } }
                    })
                }
                var cancelled = false
                do { _ = try await task.value } catch is CancellationError { cancelled = true }
                try expect(cancelled, "Cancellation was not preserved")
                try expect(milestones(collector) == [.dispatched, .headers, .firstByte, .firstTextDelta, .failed], "Cancellation recorded successful completion")
            }),
            ("cancellation at EOF is not labeled a successful return", {
                let (client, session, collector, _) = fixture(.init(body: sse([delta, complete])))
                defer { session.invalidateAndCancel() }
                let task = Task {
                    try await call(client, { entry in
                        collector.record(entry)
                        if entry.milestone == .eof { withUnsafeCurrentTask { $0?.cancel() } }
                    })
                }
                var cancelled = false
                do { _ = try await task.value } catch is CancellationError { cancelled = true }
                try expect(cancelled, "Cancellation at EOF returned success")
                try expect(milestones(collector) == [.dispatched, .headers, .firstByte, .firstTextDelta, .completed, .eof, .failed], "EOF cancellation lost failure classification")
            }),
            ("default observer disabled does not consult the injected clock", {
                let (client, session, _, clock) = fixture(.init(body: sse([delta, complete])))
                defer { session.invalidateAndCancel() }
                let answer = try await call(client)
                try expect(answer == "fixture-sensitive-answer" && clock.calls() == 0, "Disabled instrumentation changed behavior or reads the clock")
            }),
            ("token preparation failure is not falsely measured as HTTP dispatch", {
                let (unused, session, collector, clock) = fixture(.init())
                _ = unused
                defer { session.invalidateAndCancel() }
                let client = ChatGPTPlanClient(session: session, tokenSupplier: { throw PlanError.reauthenticationRequired }, invalidateToken: { _ in }, nowNanoseconds: { clock.now() })
                var caught: Error?
                do { _ = try await call(client, { collector.record($0) }) } catch { caught = error }
                try expect(caught as? PlanError == .reauthenticationRequired && collector.snapshot().isEmpty && clock.calls() == 0 && MockLedger.shared.snapshot().isEmpty, "Token failure invented dispatch or sent network request")
            })
        ]
        do {
            for (name, scenario) in scenarios { try await scenario(); print("PASS: " + name) }
            print("PASS: \(scenarios.count) production client benchmark timing scenarios; synthetic monotonic clock, isolated URLProtocol, no live inference, credentials or device access. Client return is not time-to-speech.")
        } catch {
            FileHandle.standardError.write(Data("FAIL: benchmark timing: \(error)\n".utf8)); exit(1)
        }
    }
}
