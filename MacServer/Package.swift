// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacRemoteServer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MacRemoteServer", path: "Sources/MacRemoteServer")
    ]
)
