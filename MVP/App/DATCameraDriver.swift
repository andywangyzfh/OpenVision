import Foundation
import MWDATCamera
import MWDATCore

/// The SDK boundary only. Capture ownership, cancellation, timeouts and image processing live in
/// GlassesPhotoService; tests replace this driver rather than reimplementing that behavior.
@MainActor
protocol DATCameraDriver: AnyObject {
    var registered: Bool { get }
    var deviceCount: Int { get }
    var hasSession: Bool { get }
    var sessionStarted: Bool { get }
    var sessionStopped: Bool { get }
    var connectionChanged: (@MainActor (Bool, Int) -> Void)? { get set }
    func register() async throws
    func installDeveloperComponent() async throws
    func authorizeCamera() async throws -> Bool
    func handleRegistrationURL(_ url: URL) async throws
    func cameraPermissionGranted() async throws -> Bool
    func createAndStartSession() throws
    func attachCamera(event: @escaping @MainActor @Sendable (DATCameraEvent) -> Void) throws
    func startStream()
    func capturePhoto() -> Bool
    func stopHardware()
    /// Called only after sessionStopped; releases listeners and retained hardware handles.
    func releaseStoppedHardware()
}

enum DATCameraEvent: Sendable {
    case streaming
    case streamStopped
    case failure
    case photo(Data)
}

@MainActor
final class WearablesCameraDriver: DATCameraDriver {
    private let sdkAvailable: Bool
    private var wearables: WearablesInterface { Wearables.shared }
    private var session: DeviceSession?
    private var camera: Camera?
    private var tokens: [any AnyListenerToken] = []
    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    var connectionChanged: (@MainActor (Bool, Int) -> Void)?
    var registered: Bool { sdkAvailable && wearables.registrationState == .registered }
    var deviceCount: Int { sdkAvailable ? wearables.devices.count : 0 }
    var hasSession: Bool { session != nil }
    var sessionStarted: Bool { session?.state == .started }
    var sessionStopped: Bool { session == nil || session?.state == .stopped }

    init(sdkAvailable: Bool = false, monitoring: Bool = true) {
        self.sdkAvailable = sdkAvailable
        guard sdkAvailable, monitoring else { return }
        registrationTask = Task { [weak self] in
            for await _ in Wearables.shared.registrationStateStream() {
                guard let self else { return }
                connectionChanged?(registered, deviceCount)
            }
        }
        devicesTask = Task { [weak self] in
            for await _ in Wearables.shared.devicesStream() {
                guard let self else { return }
                connectionChanged?(registered, deviceCount)
            }
        }
    }

    deinit { registrationTask?.cancel(); devicesTask?.cancel() }
    private func requireSDK() throws { guard sdkAvailable else { throw DriverFailure.sdkUnavailable } }
    func register() async throws { try requireSDK(); try await wearables.startRegistration() }
    func installDeveloperComponent() async throws { try requireSDK(); try await wearables.openDATGlassesAppUpdate() }
    func authorizeCamera() async throws -> Bool { try requireSDK(); return try await wearables.requestPermission(.camera) == .granted }
    func cameraPermissionGranted() async throws -> Bool { try requireSDK(); return try await wearables.checkPermissionStatus(.camera) == .granted }
    func handleRegistrationURL(_ url: URL) async throws { try requireSDK(); _ = try await wearables.handleUrl(url) }

    func createAndStartSession() throws {
        try requireSDK()
        guard session == nil else { throw DriverFailure.existingSession }
        guard let device = wearables.devices.first else { throw DriverFailure.noDevice }
        let created = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: device))
        session = created
        try created.start()
    }

    func attachCamera(event: @escaping @MainActor @Sendable (DATCameraEvent) -> Void) throws {
        try requireSDK()
        guard let session,
              let camera = try session.addCamera(config: StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 7)) else {
            throw DriverFailure.noCamera
        }
        self.camera = camera
        tokens.append(camera.stream.statePublisher.listen { state in
            Task { @MainActor in
                if state == .streaming { event(.streaming) }
                else if state == .stopped { event(.streamStopped) }
            }
        })
        tokens.append(camera.stream.errorPublisher.listen { _ in
            Task { @MainActor in event(.failure) }
        })
        tokens.append(camera.stream.photoDataPublisher.listen { photo in
            let data = photo.data
            Task { @MainActor in event(.photo(data)) }
        })
    }

    func startStream() { guard sdkAvailable else { return }; camera?.stream.start() }
    func capturePhoto() -> Bool { guard sdkAvailable else { return false }; return camera?.stream.capturePhoto(format: .jpeg) ?? false }
    func stopHardware() { guard sdkAvailable else { return }; camera?.stop(); session?.stop() }
    func releaseStoppedHardware() {
        guard sessionStopped else { return }
        tokens.removeAll(); camera = nil; session = nil
    }
    enum DriverFailure: Error, Equatable { case sdkUnavailable, existingSession, noDevice, noCamera }
}
