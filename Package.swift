// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MouseTrac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "MouseTrac",
            targets: ["MouseTrac"]
        )
    ],
    targets: [
        .executableTarget(
            name: "MouseTrac",
            path: "Sources/MouseTrac",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)