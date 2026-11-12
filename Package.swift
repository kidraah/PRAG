// swift-tools-version: 6.0
import PackageDescription

// Two targets on purpose:
//  - PRAGCore: pure, testable models + file-transformation services (no AppKit UI).
//  - PRAG:     the executable — window server plumbing, input monitors, SwiftUI.
// Keeping them apart lets backend work build and test independently of the UI.
let package = Package(
    name: "PRAG",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PRAG", targets: ["PRAG"]),
        .library(name: "PRAGCore", targets: ["PRAGCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode", from: "1.3.2"),
    ],
    targets: [
        .target(
            name: "PRAGCore",
            dependencies: [.product(name: "libwebp", package: "libwebp-Xcode")],
            path: "Sources/PRAGCore"
        ),
        .executableTarget(
            name: "PRAG",
            dependencies: ["PRAGCore"],
            path: "Sources/PRAG",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Quartz"),
            ]
        ),
        .testTarget(
            name: "PRAGCoreTests",
            dependencies: ["PRAGCore"],
            path: "Tests/PRAGCoreTests"
        ),
    ]
)
