// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ExtraPad",
    platforms: [.macOS(.v14)],
    targets: [
        // Private CoreGraphics virtual-display API, declared in Objective-C and
        // reached through the runtime so a missing class degrades instead of crashing.
        .target(name: "VirtualDisplayBridge"),
        .executableTarget(
            name: "ExtraPad",
            dependencies: ["VirtualDisplayBridge"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
