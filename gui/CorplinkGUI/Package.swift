// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CorplinkGUI",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CorplinkGUI",
            path: "Sources"
        )
    ]
)
