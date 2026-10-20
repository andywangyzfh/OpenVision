import XCTest
@testable import OpenVisionCore

final class CameraAccessPolicyTests: XCTestCase {
    func testOrdinaryConversationCannotAccessCameraEvenWithPermission() {
        for permission in [CameraPermission.notDetermined, .denied, .authorized] {
            for intent in [VoiceIntent.empty, .stop, .cancel, .conversation(text: "What is this?")] {
                XCTAssertEqual(CameraAccessPolicy.decision(for: intent, permission: permission), .noCapture)
            }
        }
    }

    func testExplicitPhotoRequestsRespectPermissionBeforeSingleCapture() {
        let intent = VoiceIntent.photo(question: "这是什么")
        XCTAssertEqual(CameraAccessPolicy.decision(for: intent, permission: .notDetermined), .requestPermission)
        XCTAssertEqual(CameraAccessPolicy.decision(for: intent, permission: .denied), .permissionDenied)
        XCTAssertEqual(CameraAccessPolicy.decision(for: intent, permission: .authorized), .captureOnce)
    }

    func testParsedPhotoCommandAndPolicyEndToEnd() {
        let parser = CommandParser()
        XCTAssertEqual(CameraAccessPolicy.decision(for: parser.parse("看看这个，帮我读菜单"), permission: .authorized), .captureOnce)
        XCTAssertEqual(CameraAccessPolicy.decision(for: parser.parse("我昨天拍照了"), permission: .authorized), .noCapture)
    }
}
