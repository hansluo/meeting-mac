// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingMac",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MeetingCore", targets: ["MeetingCore"]),
               .executable(name: "MeetingASRCheck", targets: ["MeetingASRCheck"])],
    targets: [
        .target(name: "CSherpaBridge"),
        .target(name: "MeetingCore", dependencies: ["CSherpaBridge"]),
        .executableTarget(name: "MeetingASRCheck", dependencies: ["MeetingCore"]),
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"])
    ],
    cxxLanguageStandard: .cxx17
)
