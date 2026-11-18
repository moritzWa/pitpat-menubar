// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PitPatBar",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PitPatKit"),
        .executableTarget(name: "PitPatBar", dependencies: ["PitPatKit"]),
        .testTarget(name: "PitPatKitTests", dependencies: ["PitPatKit"]),
    ]
)
