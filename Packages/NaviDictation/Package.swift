// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NaviDictation",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NaviDictation", targets: ["NaviDictation"]),
        .executable(name: "dictation-bench", targets: ["DictationBench"]),
    ],
    dependencies: [
        .package(path: "../NaviCore"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.2"),
    ],
    targets: [
        .target(name: "NaviDictation", dependencies: ["NaviCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .target(name: "DictationEval"),
        .executableTarget(name: "DictationBench", dependencies: ["NaviDictation", "DictationEval"]),
        .testTarget(name: "NaviDictationTests", dependencies: ["NaviDictation"]),
        .testTarget(name: "DictationEvalTests", dependencies: ["DictationEval"]),
    ]
)
