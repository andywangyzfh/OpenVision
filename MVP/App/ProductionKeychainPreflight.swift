#if DEBUG
import Foundation

/// Runs inside the actual App executable with its actual signing environment.
/// Only a random service and public synthetic strings are used, never an account record.
enum ProductionKeychainPreflight {
    private enum Failure: Error { case mismatch }

    static func run() -> String {
        let service = "org.openvision.preflight." + UUID().uuidString
        let key = "synthetic-host-id"
        let marker = FilePlanRestorationMarker(service: service, key: key)
        defer {
            try? KeychainRecord.delete(key: key, service: service)
            try? FileManager.default.removeItem(at: marker.fileURL)
        }
        do {
            guard try KeychainRecord.read(String.self, key: key, service: service) == nil else { throw Failure.mismatch }
            try KeychainRecord.write("synthetic-first", key: key, service: service)
            guard try KeychainRecord.read(String.self, key: key, service: service) == "synthetic-first" else { throw Failure.mismatch }
            try KeychainRecord.write("synthetic-updated", key: key, service: service)
            guard try KeychainRecord.read(String.self, key: key, service: service) == "synthetic-updated" else { throw Failure.mismatch }
            try KeychainRecord.delete(key: key, service: service)
            guard try KeychainRecord.read(String.self, key: key, service: service) == nil else { throw Failure.mismatch }
            // Use the real AppSupport directory, with the same random isolated namespace.
            guard try marker.isBlocked() else { throw Failure.mismatch }
            try marker.block()
            guard try marker.isBlocked() else { throw Failure.mismatch }
            try marker.allow()
            guard try !marker.isBlocked() else { throw Failure.mismatch }
            try marker.block()
            guard try marker.isBlocked() else { throw Failure.mismatch }
            try FileManager.default.removeItem(at: marker.fileURL)
            guard !FileManager.default.fileExists(atPath: marker.fileURL.path) else { throw Failure.mismatch }
            return "PASS · Production App Keychain CRUD and AppSupport restoration marker. Synthetic namespace only; no account restored or contacted."
        } catch {
            // Do not render a credential, query dictionary or arbitrary provider error.
            return "FAIL · Production App synthetic Keychain preflight did not complete. No real account was used."
        }
    }
}
#endif
