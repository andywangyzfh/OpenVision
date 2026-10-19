#if os(macOS)
import Foundation
import Network

/// A loopback-only HTTP test fixture, not an issuer or a stand-in for the production redirect
/// delegate. Source and target use different ports, so a follow is a real cross-origin request.
final class IdentityRedirectServer: @unchecked Sendable {
    struct Record { let authorization: String?; let body: Data }
    private let lock = NSLock()
    private var records: [Record] = []
    var received: [Record] { lock.lock(); defer { lock.unlock() }; return records }
    private let queue = DispatchQueue(label: "openvision.identity-redirect-fixture")
    private let listener: NWListener
    private let status: Int
    private let location: String?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var stopped = false
    private var connections: [NWConnection] = []

    init(status: Int, location: String? = nil) throws {
        self.status = status; self.location = location
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !stopped else { continuation.resume(throwing: CancellationError()); return }
                    ready = continuation
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            if let port = self.listener.port { self.ready?.resume(returning: port.rawValue); self.ready = nil }
                        case .failed(let error), .waiting(let error):
                            self.ready?.resume(throwing: error); self.ready = nil; self.close()
                        case .cancelled: self.close()
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in self?.receiveConnection(connection) }
                    listener.start(queue: queue)
                }
            }
        }, onCancel: { self.stop() })
    }
    func stop() { queue.async { [self] in close() } }
    private func close() {
        guard !stopped else { return }
        stopped = true; ready?.resume(throwing: CancellationError()); ready = nil
        listener.cancel(); connections.forEach { $0.cancel() }; connections.removeAll()
    }
    private func receiveConnection(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        connections.append(connection); connection.start(queue: queue)
        receive(connection, data: Data())
    }
    private func receive(_ connection: NWConnection, data previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, complete, error in
            guard let self, !self.stopped else { connection.cancel(); return }
            var data = previous
            if let chunk { data.append(chunk) }
            guard data.count < 65_536 else { connection.cancel(); return }
            guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
                if !complete, error == nil { self.receive(connection, data: data) } else { connection.cancel() }
                return
            }
            let lines = String(decoding: data[..<headerRange.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let fields = lines.dropFirst().compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
            let length = fields.first { $0.0 == "content-length" }.flatMap { Int($0.1) } ?? 0
            guard length >= 0, length < 65_536 else { connection.cancel(); return }
            let body = Data(data[headerRange.upperBound...])
            if body.count < length, !complete, error == nil { self.receive(connection, data: data); return }
            guard body.count >= length else { connection.cancel(); return }
            self.lock.lock()
            self.records.append(Record(authorization: fields.first { $0.0 == "authorization" }?.1, body: Data(body.prefix(length))))
            self.lock.unlock()
            var response = "HTTP/1.1 \(self.status) Test\r\nContent-Length: 0\r\nConnection: close\r\n"
            if let location = self.location { response += "Location: \(location)\r\n" }
            response += "\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
#endif
