// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitPico",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "GitPico", targets: ["GitPico"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "GitCore"),
        .executableTarget(name: "GitPico", dependencies: ["GitCore", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "GitCoreTests", dependencies: ["GitCore"]),
        .testTarget(name: "GitPicoTests", dependencies: ["GitPico", "GitCore"])
    ]
)
