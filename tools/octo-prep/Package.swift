// swift-tools-version: 6.0
// octo-prep: turns pinned 万象拼音 (rime-wanxiang) files into OctoDot's
// normalized sources. It runs on developer machines and in CI, never in
// the IME, and has no dependencies, so building it needs no network.
import PackageDescription

let package = Package(
    name: "octo-prep",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "OctoPrep"),
        .executableTarget(name: "octo-prep", dependencies: ["OctoPrep"]),
        .testTarget(name: "OctoPrepTests", dependencies: ["OctoPrep"]),
    ]
)
