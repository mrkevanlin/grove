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
        // Resources (menu bar icon) are copied into the .app by scripts/install.sh.
        .executableTarget(name: "GroveApp", dependencies: ["GroveCore"], exclude: ["Resources"]),
        .executableTarget(name: "grove", dependencies: ["GroveCore"]),
    ]
)
