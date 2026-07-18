// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceOpsCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VoiceOpsCore", targets: ["VoiceOpsCore"]),
        .executable(name: "voiceops-mock-client", targets: ["MockClient"]),
        .executable(name: "voiceops-eval-probe", targets: ["EvalProbe"]),
    ],
    targets: [
        .target(name: "VoiceOpsCore"),
        .executableTarget(name: "MockClient", dependencies: ["VoiceOpsCore"]),
        .executableTarget(name: "EvalProbe", dependencies: ["VoiceOpsCore"]),
        .testTarget(name: "VoiceOpsCoreTests", dependencies: ["VoiceOpsCore"]),
    ]
)
