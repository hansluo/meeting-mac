// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingMac",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MeetingCore", targets: ["MeetingCore"])],
    targets: [
        .target(name: "MeetingCore"),
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"])
    ]
)
