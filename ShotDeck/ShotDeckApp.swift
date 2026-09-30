import SwiftUI
import ShotDeckKit

/// ShotDeck app entry point.
///
/// iPhone-only by user directive 2026-09-15 (`TARGETED_DEVICE_FAMILY = 1`
/// in every build configuration; CI enforces it pre- and post-build).
/// Zero-network by construction: no network APIs anywhere in app or
/// package sources — CI enforces an empty-allowlist scan.
@main
struct ShotDeckApp: App {
    var body: some SwiftUI.Scene {
        WindowGroup {
            ContentView()
        }
    }
}
