// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitPico",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "GitPico", targets: ["GitPico"])],
    targets: [
        .target(name: "GitCore"),
        .executableTarget(name: "GitPico", dependencies: ["GitCore"]),
        .testTarget(name: "GitCoreTests", dependencies: ["GitCore"]),
        .testTarget(name: "GitPicoTests", dependencies: ["GitPico", "GitCore"])
    ]
)
