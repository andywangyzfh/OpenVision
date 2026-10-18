import Combine
import Foundation
import MWDATCamera
import MWDATCore
import UIKit

/// One explicit request creates one camera stream, obtains a new JPEG, and closes the session.
/// No phone-camera fallback, recordings, continuous preview or persistent image cache.
@MainActor
final class GlassesPhotoService: ObservableObject {
    @Published private(set) var registered = false
    @Published private(set) var deviceCount = 0
    @Published private(set) var cameraActive = false
    private var wearables: WearablesInterface { Wearables.shared }
    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var session: DeviceSession?
    private var camera: Camera?
    private var tokens: [any AnyListenerToken] = []
    private var streamState: StreamState = .stopped
    private var photoData: Data?
    private var captureID: UUID?
    private var captureInFlight = false
    private var operationGeneration = 0
    private var cleanupTask: Task<Bool, Never>?
    private var failed = false

    init(monitoring: Bool = true) {
        guard monitoring else { return }
        registered = wearables.registrationState == .registered
        deviceCount = wearables.devices.count
        registrationTask = Task { [weak self] in
            for await state in Wearables.shared.registrationStateStream() {
                guard let self else { return }
                self.registered = state == .registered
            }
        }
        devicesTask = Task { [weak self] in
            for await devices in Wearables.shared.devicesStream() {
                guard let self else { return }
                self.deviceCount = devices.count
            }
        }
    }

    func register() async throws { try await wearables.startRegistration() }
    func installDeveloperComponent() async throws { try await wearables.openDATGlassesAppUpdate() }
    func authorizeCamera() async throws -> Bool { try await wearables.requestPermission(.camera) == .granted }

    func captureJPEG() async throws -> Data {
        // Keep ownership through permission awaits and teardown. Stop invalidates this operation,
        // but a second capture cannot overtake it and then be closed by its late error handler.
        guard !captureInFlight else { throw PhotoFailure.busy }
        captureInFlight = true
        defer { captureInFlight = false }
        let generation = operationGeneration
        if session != nil || cleanupTask != nil || cameraActive {
            guard await close() else { throw PhotoFailure.teardown }
        }
        try Task.checkCancellation()
        guard generation == operationGeneration else { throw CancellationError() }
        guard registered, let device = wearables.devices.first else { throw PhotoFailure.noGlasses }
        let id = UUID()
        captureID = id; photoData = nil; failed = false; streamState = .stopped
        do {
            let permission = try await wearables.checkPermissionStatus(.camera)
            try checkActiveCapture(id, generation: generation)
            guard permission == .granted else { throw PhotoFailure.permission }
            let session = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: device))
            self.session = session
            try session.start()
            try await waitUntil(seconds: 15, id: id, generation: generation) { session.state == .started }
            guard let camera = try session.addCamera(config: StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 7)) else {
                throw PhotoFailure.capture
            }
            self.camera = camera
            tokens.append(camera.stream.statePublisher.listen { [weak self] state in
                Task { @MainActor [weak self] in
                    guard self?.captureID == id else { return }
                    self?.streamState = state
                }
            })
            tokens.append(camera.stream.errorPublisher.listen { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard self?.captureID == id else { return }; self?.failed = true
                }
            })
            tokens.append(camera.stream.photoDataPublisher.listen { [weak self] photo in
                let data = photo.data
                Task { @MainActor [weak self] in
                    guard self?.captureID == id else { return }; self?.photoData = data
                }
            })
            cameraActive = true
            camera.stream.start()
            try await waitUntil(seconds: 15, id: id, generation: generation) { self.streamState == .streaming }
            guard camera.stream.capturePhoto(format: .jpeg) else { throw PhotoFailure.capture }
            try await waitUntil(seconds: 12, id: id, generation: generation) { self.photoData != nil }
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
        // Unstructured cleanup deliberately does not inherit the canceled capture's lifetime.
        // Retain hardware references until SDK teardown is confirmed.
        _ = startCleanup()
    }

    @discardableResult private func close() async -> Bool {
        await startCleanup().value
    }

    private func startCleanup() -> Task<Bool, Never> {
        if let cleanupTask { return cleanupTask }
        captureID = nil
        camera?.stop(); session?.stop()
        photoData = nil
        let task = Task { @MainActor [self] in
            defer { cleanupTask = nil }
            let clock = ContinuousClock()
            let end = clock.now.advanced(by: .seconds(4))
            while let session, session.state != .stopped, clock.now < end {
                // This task is not canceled by stop()/turn cancellation. If it ever is canceled,
                // return instead of swallowing cancellation and spinning on the main actor.
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return false }
            }
            let closed = session == nil || session?.state == .stopped
            if closed {
                tokens.removeAll(); camera = nil; session = nil
                streamState = .stopped; cameraActive = false
            }
            // On timeout keep the session/camera and the conservative Camera on state. A later
            // Stop or capture retries this same teardown before opening any new hardware.
            return closed
        }
        cleanupTask = task
        return task
    }

    private func checkActiveCapture(_ id: UUID, generation: Int) throws {
        try Task.checkCancellation()
        guard generation == operationGeneration, captureID == id else { throw CancellationError() }
    }

    private func waitUntil(seconds: TimeInterval, id: UUID, generation: Int, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(seconds))
        while true {
            // Check even when the condition is already true, before the next hardware action.
            try checkActiveCapture(id, generation: generation)
            guard !failed else { throw PhotoFailure.capture }
            if condition() { return }
            guard clock.now < end, session?.state != .stopped else { throw PhotoFailure.capture }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    enum PhotoFailure: Error { case busy, noGlasses, permission, capture, teardown }
}
