// swift-tools-version: 6.0
import PackageDescription

// Two targets on purpose:
//  - NotchPipeCore: pure, testable models + file-transformation services (no AppKit UI).
//  - NotchPipe:     the executable — window server plumbing, input monitors, SwiftUI.
// Keeping them apart lets backend work build and test independently of the UI.
let package = Package(
    name: "NotchPipe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotchPipe", targets: ["NotchPipe"]),
        .library(name: "NotchPipeCore", targets: ["NotchPipeCore"]),
    ],
    targets: [
        .target(
            name: "NotchPipeCore",
            path: "Sources/NotchPipeCore"
        ),
        .executableTarget(
            name: "NotchPipe",
            dependencies: ["NotchPipeCore"],
            path: "Sources/NotchPipe",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Quartz"),
            ]
        ),
        .testTarget(
            name: "NotchPipeCoreTests",
            dependencies: ["NotchPipeCore"],
            path: "Tests/NotchPipeCoreTests"
        ),
    ]
)
