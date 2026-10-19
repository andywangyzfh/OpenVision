import AppKit
import CryptoKit
import Foundation
import OpenVisionCore
import SubscriptionCore

struct BenchmarkFixture: Sendable {
    let id: String
    let language: ConversationLanguage
    let prompt: String
    let history: [PlanTurn]
    let image: Data?
    var turns: [PlanTurn] { history + [.init(role: "user", text: prompt, imageJPEG: image)] }
    var instructions: String { language.systemPrompt(for: prompt) }
}

@MainActor
enum BenchmarkSuite {
    // Public synthetic cards only. No local photos, files, camera or microphone are read.
    static func card(color: NSColor, triangle: Bool, number: String) throws -> Data {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        color.setFill()
        if triangle {
            let path = NSBezierPath(); path.move(to: .init(x: 256, y: 448))
            path.line(to: .init(x: 64, y: 64)); path.line(to: .init(x: 448, y: 64)); path.close(); path.fill()
        } else { NSBezierPath(ovalIn: NSRect(x: 64, y: 64, width: 384, height: 384)).fill() }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 120), .foregroundColor: NSColor.white]
        let label = NSAttributedString(string: number, attributes: attributes)
        let textSize = label.size(); label.draw(at: .init(x: (512 - textSize.width) / 2, y: triangle ? 132 : 182))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { throw PlanError.malformedResponse }
        return jpeg
    }
    static func fixtures() throws -> (probe: BenchmarkFixture, cases: [BenchmarkFixture]) {
        let a = try card(color: .systemBlue, triangle: false, number: "7")
        let b = try card(color: .systemRed, triangle: true, number: "4")
        let photoPrompt = "照片里最大的有色图形是什么颜色、什么形状，里面是什么数字？只用一句简短中文回答。"
        return (
            .init(id: "vision_probe_A", language: .chinese, prompt: photoPrompt, history: [], image: a),
            [
                .init(id: "cn_practical", language: .chinese, prompt: "我在陌生街区，想步行去地铁站。你不知道我的位置，也没有地图工具。请用两句中文告诉我下一步怎么做。", history: [], image: nil),
                .init(id: "en_practical", language: .english, prompt: "I have flour, eggs, and water. Suggest one simple breakfast in two short English sentences. Do not assume I have any other ingredients.", history: [], image: nil),
                .init(id: "context_42", language: .chinese, prompt: "刚才我们约定的公开测试数字是多少？只回答数字。", history: [.init(role: "user", text: "这是公开测试，不是个人资料。请记住数字42。"), .init(role: "assistant", text: "好的，记住公开测试数字42。")], image: nil),
                .init(id: "vision_B", language: .chinese, prompt: photoPrompt, history: [], image: b)
            ])
    }
    static func imageHash(_ data: Data?) -> String? { data.map { Data(SHA256.hash(data: $0)).map { String(format: "%02x", $0) }.joined() } }
    static func checks(id: String, answer: String) -> [String: Bool] {
        let han = answer.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }
        var checks = ["nonempty": !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "brief": answer.count <= 220]
        switch id {
        case "vision_probe_A": checks["facts"] = answer.contains("蓝") && answer.contains("圆") && answer.contains("7"); checks["language"] = han
        case "vision_B": checks["facts"] = answer.contains("红") && answer.contains("三角") && answer.contains("4"); checks["language"] = han
        case "context_42": checks["facts"] = answer.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) == "42"
        case "en_practical": checks["language"] = !han
        default: checks["language"] = han
        }
        return checks
    }
}

struct BenchmarkModel: Codable, Sendable {
    let slug: String
    let modalities: [String]?
    var imageCapability: String { modalities.map { $0.contains("image") ? "declared_image" : "declared_no_image" } ?? "unknown_requires_probe" }
}

struct BenchmarkJob: Sendable {
    let modelIndex: Int
    let fixtureIndex: Int // -1 is the separate fresh-session image probe.
    let repetition: Int
    var connection: String { fixtureIndex < 0 ? "fresh_URLSession_probe" : "reused_URLSession" }
}

enum BenchmarkSchedule {
    static func make(modelCount: Int, fixtureCount: Int) throws -> [BenchmarkJob] {
        guard modelCount == 3, fixtureCount == 4 else { throw PlanError.service("benchmark_configuration_invalid") }
        var jobs = (0..<modelCount).map { BenchmarkJob(modelIndex: $0, fixtureIndex: -1, repetition: -1) }
        for repetition in 0..<3 {
            for offset in 0..<fixtureCount {
                for modelOffset in 0..<modelCount {
                    jobs.append(.init(modelIndex: (modelOffset + offset + repetition + 1) % modelCount,
                                      fixtureIndex: (offset + repetition) % fixtureCount, repetition: repetition))
                }
            }
        }
        return jobs
    }
    static func checkInvariants() throws {
        let jobs = try make(modelCount: 3, fixtureCount: 4)
        precondition(jobs.count == 39)
        precondition(jobs.prefix(3).allSatisfy { $0.repetition == -1 && $0.fixtureIndex == -1 })
        for m in 0..<3 {
            precondition(jobs.filter { $0.modelIndex == m && $0.fixtureIndex == -1 }.count == 1)
            for f in 0..<4 {
                let repetitions = jobs.filter { $0.modelIndex == m && $0.fixtureIndex == f }.map(\.repetition)
                precondition(repetitions.count == 3 && Set(repetitions) == [0, 1, 2])
            }
        }
        for offset in stride(from: 3, to: 39, by: 3) {
            precondition(Set(jobs[offset..<(offset + 3)].map(\.modelIndex)) == [0, 1, 2])
        }
        do { _ = try make(modelCount: 4, fixtureCount: 4); preconditionFailure("Invalid budget accepted") }
        catch PlanError.service { }
    }
}

struct BenchmarkRow: Codable, Sendable {
    let index: Int
    let model: String
    let fixture: String
    let repetition: Int
    let connection: String
    let outcome: String
    let errorCategory: String?
    let answer: String?
    let checks: [String: Bool]
    let callElapsedNanoseconds: UInt64
    let observations: [PlanRequestObservation]
}

final class BenchmarkObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PlanRequestObservation] = []
    func append(_ event: PlanRequestObservation) { lock.lock(); defer { lock.unlock() }; events.append(event) }
    func snapshot() -> [PlanRequestObservation] { lock.lock(); defer { lock.unlock() }; return events }
}

// Safe categories only. Never persist arbitrary Error descriptions or response error text.
func benchmarkError(_ error: Error) -> String {
    if error is CancellationError { return "cancelled" }
    if let error = error as? URLError { return "url_\(error.code.rawValue)" }
    guard let plan = error as? PlanError else { return "unclassified_failure" }
    switch plan {
    case .denied: return "authorization_denied"
    case .reauthenticationRequired: return "reauthentication_required"
    case .missingPermission: return "permission_missing"
    case .malformedResponse: return "malformed_response"
    case .incompleteStream: return "incomplete_stream"
    case .invalidIdentity: return "identity_invalid"
    case .invalidCallback: return "callback_invalid"
    case .service(let code):
        let allowed: Set<String> = ["http_400", "http_401", "http_403", "http_404", "http_408", "http_429", "http_500", "http_502", "http_503", "http_504", "subscription_sharing_usage_limit_exceeded", "empty_reply", "request_failed", "reply_too_large", "sign_in_timeout"]
        return allowed.contains(code) ? code : "service_failure_redacted"
    }
}
