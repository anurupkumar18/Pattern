// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceOpsCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VoiceOpsCore", targets: ["VoiceOpsCore"]),
        .executable(name: "voiceops-mock-client", targets: ["MockClient"]),
    ],
    targets: [
        .target(name: "VoiceOpsCore"),
        .executableTarget(name: "MockClient", dependencies: ["VoiceOpsCore"]),
        .testTarget(name: "VoiceOpsCoreTests", dependencies: ["VoiceOpsCore"]),
    ]
)
