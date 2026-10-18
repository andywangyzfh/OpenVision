import Foundation

public enum CameraPermission: Equatable, Sendable {
    case notDetermined, denied, authorized
}

public enum PhotoAccessDecision: Equatable, Sendable {
    case noCapture
    case requestPermission
    case permissionDenied
    case captureOnce
}

/// Shared guard for the app and tests. This MVP never starts a persistent camera stream implicitly.
public enum CameraAccessPolicy {
    public static func decision(for intent: VoiceIntent, permission: CameraPermission) -> PhotoAccessDecision {
        guard case .photo = intent else { return .noCapture }
        switch permission {
        case .notDetermined: return .requestPermission
        case .denied: return .permissionDenied
        case .authorized: return .captureOnce
        }
    }
}
