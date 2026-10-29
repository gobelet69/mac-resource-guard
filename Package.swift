// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacResourceGuard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MacResourceGuardCore",
            targets: ["MacResourceGuardCore"]
        ),
        .executable(
            name: "MacResourceGuard",
            targets: ["MacResourceGuardApp"]
        )
    ],
    targets: [
        .target(
            name: "MacResourceGuardCore",
            path: "Sources/MacResourceGuardCore"
        ),
        .executableTarget(
            name: "MacResourceGuardApp",
            dependencies: ["MacResourceGuardCore"],
            path: "Sources/MacResourceGuardApp",
            exclude: [
                "Resources/Info.plist",
                "Resources/MacResourceGuard.entitlements",
                "Resources/Assets.xcassets"
            ]
        ),
        .testTarget(
            name: "MacResourceGuardTests",
            dependencies: ["MacResourceGuardCore", "MacResourceGuardApp"],
            path: "Tests/MacResourceGuardTests"
        )
    ]
)
