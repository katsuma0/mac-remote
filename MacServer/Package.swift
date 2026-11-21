// swift-tools-version:5.9
import PackageDescription

// Command-line / development build of the Mac side. The App Store builds come from
// Couchpad.xcodeproj at the top of the repository, which uses these same source folders.
let package = Package(
    name: "MacRemoteServer",
    platforms: [.macOS(.v13)],
    targets: [
        // Shared with the iPhone app: protocol, pairing and encryption.
        .target(name: "RemoteCore", path: "Sources/RemoteCore"),
        .executableTarget(name: "MacRemoteServer", dependencies: ["RemoteCore"], path: "Sources/MacRemoteServer"),
        .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"], path: "Tests/RemoteCoreTests"),
    ]
)
