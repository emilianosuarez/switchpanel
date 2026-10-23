// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Switchpanel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Switchpanel",
            path: "Sources/Switchpanel",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        ),
    ]
)
