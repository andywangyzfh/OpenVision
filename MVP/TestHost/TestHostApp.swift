import SwiftUI

/// Isolated XCTest host. It never creates an account, microphone or glasses service.
@main
struct OpenVisionPlatformTestHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("OpenVision platform tests · synthetic data only")
        }
    }
}
