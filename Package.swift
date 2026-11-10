// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ConfigBox",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CBridge",
            path: "Sources/CBridge",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("IOKit"),
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"]),
            ]
        ),
        .executableTarget(
            name: "ConfigBox",
            dependencies: ["CBridge"],
            path: "Sources/ConfigBox",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "ConfigBoxTests",
            dependencies: ["ConfigBox"],
            path: "Tests/ConfigBoxTests"
        ),
    ]
)
