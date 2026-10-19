import Combine
import Foundation
import UIKit

/// One explicit request creates one camera stream, obtains a new JPEG, and closes the session.
/// No phone-camera fallback, recordings, continuous preview or persistent image cache.
@MainActor
final class GlassesPhotoService: ObservableObject {
    struct CaptureIntent: Sendable, Equatable {
        fileprivate let requestID: UUID
        fileprivate let nonce: UUID
        fileprivate let epoch: Int
    }
    struct Timing {
        var sessionStart: TimeInterval = 15
        var streamStart: TimeInterval = 15
        var photo: TimeInterval = 12
        var teardown: TimeInterval = 4
        var poll: TimeInterval = 0.05
    }

    @Published private(set) var registered = false
    @Published private(set) var deviceCount = 0
    @Published private(set) var cameraActive = false
    let sdkAvailable: Bool
    private let driver: any DATCameraDriver
    private let timing: Timing
    private var streaming = false
    private var photoData: Data?
    private var captureID: UUID?
    private var captureInFlight = false
    private var operationGeneration = 0
    private var cleanupTask: Task<Bool, Never>?
    private var failed = false
    private var permittedIntent: CaptureIntent?
    private var intentEpoch = 0
    private var activeIntentEpoch: Int?

    /// UI activity ends before SDK teardown can finish. Independent DAT sessions must
    /// wait for the actual capture owner and every retained hardware handle to release.
    var canStartIndependentSession: Bool {
        !captureInFlight && !driver.hasSession && cleanupTask == nil && !cameraActive
    }

    init(monitoring: Bool = true, sdkAvailable: Bool = false, driver: (any DATCameraDriver)? = nil, timing: Timing = Timing()) {
        let selected = driver ?? WearablesCameraDriver(sdkAvailable: sdkAvailable, monitoring: monitoring)
        self.driver = selected
        self.timing = timing
        self.sdkAvailable = sdkAvailable
        // Preserve fixture mode: constructing monitoring:false must not access Wearables.shared.
        guard sdkAvailable, monitoring || driver != nil else { return }
        registered = selected.registered
        deviceCount = selected.deviceCount
        selected.connectionChanged = { [weak self] registered, count in
            self?.registered = registered
            self?.deviceCount = count
        }
    }

    private func requireSDK() throws { guard sdkAvailable else { throw PhotoFailure.sdkUnavailable } }
    func register() async throws { try requireSDK(); try await driver.register() }
    func installDeveloperComponent() async throws { try requireSDK(); try await driver.installDeveloperComponent() }
    func authorizeCamera() async throws -> Bool { try requireSDK(); return try await driver.authorizeCamera() }
    func handleRegistrationURL(_ url: URL) async throws { try requireSDK(); try await driver.handleRegistrationURL(url) }

    /// Called only after the App's positive confirmation. Minting touches no SDK or permission.
    func authorizeSinglePhoto(requestID: UUID) throws -> CaptureIntent {
        guard !captureInFlight else { throw PhotoFailure.busy }
        let intent = CaptureIntent(requestID: requestID, nonce: UUID(), epoch: intentEpoch)
        permittedIntent = intent
        return intent
    }

    func revokeUnconsumedPhotoIntents() { permittedIntent = nil }

    func captureJPEG(intent: CaptureIntent?) async throws -> Data {
        guard let intent, permittedIntent == intent, intent.epoch == intentEpoch else { throw PhotoFailure.invalidIntent }
        permittedIntent = nil // Consume before the first await; replay cannot open another session.
        try requireSDK()
        // Keep ownership through permission awaits and teardown. Stop invalidates this operation,
        // but a second capture cannot overtake it and then be closed by its late error handler.
        guard !captureInFlight else { throw PhotoFailure.busy }
        captureInFlight = true
        defer { captureInFlight = false }
        let generation = operationGeneration
        activeIntentEpoch = intent.epoch
        if driver.hasSession || cleanupTask != nil || cameraActive {
            guard await close() else { throw PhotoFailure.teardown }
        }
        try Task.checkCancellation()
        guard generation == operationGeneration else { throw CancellationError() }
        guard registered, driver.deviceCount > 0 else { throw PhotoFailure.noGlasses }
        let id = UUID()
        captureID = id; photoData = nil; failed = false; streaming = false
        do {
            let permission = try await driver.cameraPermissionGranted()
            try checkActiveCapture(id, generation: generation)
            guard permission else { throw PhotoFailure.permission }
            try checkActiveCapture(id, generation: generation)
            try driver.createAndStartSession()
            try await waitUntil(seconds: timing.sessionStart, id: id, generation: generation) { self.driver.sessionStarted }
            try checkActiveCapture(id, generation: generation)
            try driver.attachCamera { [weak self] event in
                guard let self, captureID == id else { return }
                switch event {
                case .streaming: streaming = true
                case .streamStopped: streaming = false
                case .failure: failed = true
                case .photo(let data): photoData = data
                }
            }
            cameraActive = true
            try checkActiveCapture(id, generation: generation)
            driver.startStream()
            try await waitUntil(seconds: timing.streamStart, id: id, generation: generation) { self.streaming }
            try checkActiveCapture(id, generation: generation)
            guard driver.capturePhoto() else { throw PhotoFailure.capture }
            try await waitUntil(seconds: timing.photo, id: id, generation: generation) { self.photoData != nil }
            guard let data = photoData, let image = UIImage(data: data) else { throw PhotoFailure.capture }
            // Bound request size and remove original EXIF/GPS metadata by re-encoding pixel data.
            let longest = max(image.size.width, image.size.height)
            guard longest > 0 else { throw PhotoFailure.capture }
            let scale = min(1, 1280 / longest)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            guard let jpeg = rendered.jpegData(compressionQuality: 0.75), jpeg.count <= 4_000_000 else { throw PhotoFailure.capture }
            guard await close() else { throw PhotoFailure.teardown }
            try Task.checkCancellation()
            guard generation == operationGeneration else { throw CancellationError() }
            return jpeg
        } catch {
            let closed = await close()
            if !closed { throw PhotoFailure.teardown }
            throw error
        }
    }

    func stop() {
        operationGeneration += 1
        intentEpoch += 1; permittedIntent = nil
        guard sdkAvailable else { return }
        // Unstructured cleanup deliberately does not inherit the canceled capture's lifetime.
        // Retain hardware references until SDK teardown is confirmed.
        _ = startCleanup()
    }

    @discardableResult private func close() async -> Bool { await startCleanup().value }

    private func startCleanup() -> Task<Bool, Never> {
        if let cleanupTask { return cleanupTask }
        captureID = nil
        driver.stopHardware()
        photoData = nil
        let task = Task { @MainActor [self] in
            defer { cleanupTask = nil }
            let clock = ContinuousClock()
            let end = clock.now.advanced(by: .seconds(timing.teardown))
            while !driver.sessionStopped, clock.now < end {
                // Never swallow cancellation into an immediately throwing busy loop.
                do { try await Task.sleep(for: .seconds(max(0.001, timing.poll))) }
                catch { return false }
            }
            let closed = driver.sessionStopped
            if closed {
                driver.releaseStoppedHardware()
                streaming = false; cameraActive = false
            }
            // On timeout retain handles and conservative Camera on state. The next Stop/capture
            // retries teardown before any new hardware can be created.
            return closed
        }
        cleanupTask = task
        return task
    }

    private func checkActiveCapture(_ id: UUID, generation: Int) throws {
        try Task.checkCancellation()
        guard generation == operationGeneration, captureID == id, activeIntentEpoch == intentEpoch else { throw PhotoFailure.intentRevoked }
    }

    private func waitUntil(seconds: TimeInterval, id: UUID, generation: Int, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(seconds))
        while true {
            try checkActiveCapture(id, generation: generation)
            guard !failed else { throw PhotoFailure.capture }
            if condition() { return }
            guard clock.now < end, !driver.sessionStopped else { throw PhotoFailure.capture }
            try await Task.sleep(for: .seconds(max(0.001, timing.poll)))
        }
    }

    enum PhotoFailure: Error, Equatable { case invalidIntent, intentRevoked, sdkUnavailable, busy, noGlasses, permission, capture, teardown }
}
