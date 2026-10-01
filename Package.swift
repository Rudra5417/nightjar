// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NightjarCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "NightjarCore", targets: ["NightjarCore"]),
        .executable(name: "nightjar-probe", targets: ["nightjar-probe"]),
    ],
    targets: [
        .target(name: "NightjarCore"),
        .executableTarget(name: "nightjar-probe", dependencies: ["NightjarCore"]),
        .testTarget(name: "NightjarCoreTests", dependencies: ["NightjarCore"]),
    ]
)
