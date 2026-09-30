// swift-tools-version: 6.0
import PackageDescription

// ShotDeckStore — local SQLite persistence for the ShotDeck domain.
//
// Storage: GRDB (SQLite). On Linux, GRDB links the system SQLite via its
// systemLibrary target (apt provider: libsqlite3-dev — installed by the CI
// Linux job before `swift test`). On Apple platforms it links the system
// libsqlite3 shipped with the OS/SDK.
//
// Zero-network by construction: this package only ever touches a local
// file. No network APIs are used anywhere (enforced by
// scripts/check_zero_network.sh).
let package = Package(
    name: "ShotDeckStore",
    platforms: [
        .iOS("26.0"),
        .macOS("15.0"),
    ],
    products: [
        .library(name: "ShotDeckStore", targets: ["ShotDeckStore"]),
        .executable(name: "ShotDeckFixtureTool", targets: ["ShotDeckFixtureTool"]),
    ],
    dependencies: [
        .package(path: "../ShotDeckKit"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "ShotDeckStore",
            dependencies: [
                "ShotDeckKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "ShotDeckFixtureTool",
            dependencies: [
                "ShotDeckStore",
                "ShotDeckKit",
            ]
        ),
        .testTarget(
            name: "ShotDeckStoreTests",
            dependencies: ["ShotDeckStore"]
        ),
    ]
)
