// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "untunnel",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "UntunnelEngine", targets: ["UntunnelEngine"]),
        .executable(name: "untunnel", targets: ["Untunnel"]),
    ],
    targets: [
        .target(name: "UntunnelKernels"),
        .target(name: "UntunnelEngine", dependencies: ["UntunnelKernels"]),
        .target(name: "UntunnelDSP"),
        .target(name: "UntunnelAudio", dependencies: ["UntunnelDSP"]),
        .target(name: "UntunnelDriverCore"),
        .executableTarget(
            name: "Untunnel",
            dependencies: ["UntunnelEngine", "UntunnelDSP", "UntunnelAudio"]
        ),
        .testTarget(name: "UntunnelEngineTests", dependencies: ["UntunnelEngine"]),
        .testTarget(name: "UntunnelDSPTests", dependencies: ["UntunnelDSP"]),
        .testTarget(name: "UntunnelAudioTests", dependencies: ["UntunnelAudio"]),
        .testTarget(name: "UntunnelDriverCoreTests", dependencies: ["UntunnelDriverCore"]),
        .testTarget(name: "UntunnelTests", dependencies: ["Untunnel"]),
    ],
    swiftLanguageModes: [.v6]
)
