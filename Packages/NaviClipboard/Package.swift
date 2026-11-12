// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NaviClipboard",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NaviClipboard", targets: ["NaviClipboard"]),
        .executable(name: "history-bench", targets: ["HistoryBench"]),
    ],
    dependencies: [.package(path: "../NaviCore")],
    targets: [
        .target(name: "NaviClipboard", dependencies: ["NaviCore"]),
        .executableTarget(name: "HistoryBench", dependencies: ["NaviClipboard", "NaviCore"]),
        .testTarget(name: "NaviClipboardTests", dependencies: ["NaviClipboard", "NaviCore"]),
    ]
)
