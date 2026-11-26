// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IOSVNCBridge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "IOSVNCBridge", path: "Sources/IOSVNCBridge")
    ]
)
