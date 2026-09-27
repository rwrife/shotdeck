// swift-tools-version: 6.0
import PackageDescription

/// Pure Swift domain package for ShotDeck.
///
/// Keep this package free of UI, networking, and Apple-only frameworks so its
/// deterministic rules remain testable on Linux and Apple runners.
let package = Package(
    name: "ShotDeckKit",
    platforms: [
        .iOS("26.0"),
    ],
    products: [
        .library(name: "ShotDeckKit", targets: ["ShotDeckKit"]),
    ],
    targets: [
        .target(name: "ShotDeckKit"),
        .testTarget(name: "ShotDeckKitTests", dependencies: ["ShotDeckKit"]),
    ]
)
