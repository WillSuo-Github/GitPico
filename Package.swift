// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitPico",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "GitPico", targets: ["GitPico"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "GitCore", resources: [.process("Localizable.xcstrings")]),
        .executableTarget(name: "GitPico", dependencies: ["GitCore", .product(name: "Sparkle", package: "Sparkle")], resources: [.process("Localizable.xcstrings")]),
        .testTarget(name: "GitCoreTests", dependencies: ["GitCore"]),
        .testTarget(name: "GitPicoTests", dependencies: ["GitPico", "GitCore"])
    ]
)
