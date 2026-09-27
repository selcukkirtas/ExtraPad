// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ExtraPad",
    platforms: [.macOS(.v14), .iOS(.v15)],
    targets: [
        // Private CoreGraphics virtual-display API, declared in Objective-C and
        // reached through the runtime so a missing class degrades instead of crashing.
        .target(name: "VirtualDisplayBridge"),
        // Everything both sides of the wire need, and nothing platform
        // specific: the iOS client will depend on exactly this.
        .target(name: "ExtraPadProtocol"),
        .testTarget(name: "ExtraPadProtocolTests", dependencies: ["ExtraPadProtocol"]),
        .executableTarget(
            name: "ExtraPad",
            dependencies: ["VirtualDisplayBridge", "ExtraPadProtocol"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
