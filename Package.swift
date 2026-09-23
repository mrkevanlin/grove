// swift-tools-version:5.10
import PackageDescription

// The app executable is "GroveApp" rather than "Grove" so it can't collide with the
// `grove` CLI binary on a case-insensitive filesystem.
let package = Package(
    name: "Grove",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GroveApp", targets: ["GroveApp"]),
        .executable(name: "grove", targets: ["grove"]),
    ],
    targets: [
        .target(name: "GroveCore"),
        .executableTarget(name: "GroveApp", dependencies: ["GroveCore"]),
        .executableTarget(name: "grove", dependencies: ["GroveCore"]),
    ]
)
