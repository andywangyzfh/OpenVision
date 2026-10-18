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
    private var wearables: WearablesInterface { Wearables.shared }
    private var session: DeviceSession?
    private var camera: Camera?
    private var tokens: [any AnyListenerToken] = []
    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    var connectionChanged: (@MainActor (Bool, Int) -> Void)?
    var registered: Bool { wearables.registrationState == .registered }
    var deviceCount: Int { wearables.devices.count }
    var hasSession: Bool { session != nil }
    var sessionStarted: Bool { session?.state == .started }
    var sessionStopped: Bool { session == nil || session?.state == .stopped }

    init(monitoring: Bool = true) {
        guard monitoring else { return }
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
    func register() async throws { try await wearables.startRegistration() }
    func installDeveloperComponent() async throws { try await wearables.openDATGlassesAppUpdate() }
    func authorizeCamera() async throws -> Bool { try await wearables.requestPermission(.camera) == .granted }
    func cameraPermissionGranted() async throws -> Bool { try await wearables.checkPermissionStatus(.camera) == .granted }

    func createAndStartSession() throws {
        guard session == nil else { throw DriverFailure.existingSession }
        guard let device = wearables.devices.first else { throw DriverFailure.noDevice }
        let created = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: device))
        session = created
        try created.start()
    }

    func attachCamera(event: @escaping @MainActor @Sendable (DATCameraEvent) -> Void) throws {
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

    func startStream() { camera?.stream.start() }
    func capturePhoto() -> Bool { camera?.stream.capturePhoto(format: .jpeg) ?? false }
    func stopHardware() { camera?.stop(); session?.stop() }
    func releaseStoppedHardware() {
        guard sessionStopped else { return }
        tokens.removeAll(); camera = nil; session = nil
    }
    enum DriverFailure: Error { case existingSession, noDevice, noCamera }
}
