// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingMac",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MeetingCore", targets: ["MeetingCore"]),
               .executable(name: "MeetingASRCheck", targets: ["MeetingASRCheck"]),
               .executable(name: "MeetingMacApp", targets: ["MeetingMacApp"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CSherpaBridge"),
        .target(name: "CManagedArchive", linkerSettings: [.linkedLibrary("archive")]),
        .target(name: "MeetingCore", dependencies: ["CSherpaBridge", "CManagedArchive", "CSQLite"], resources: [.process("Resources")]),
        .executableTarget(name: "MeetingASRCheck", dependencies: ["MeetingCore"]),
        .executableTarget(name: "MeetingMacApp", dependencies: ["MeetingCore"]),
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"])
    ],
    cxxLanguageStandard: .cxx17
)
