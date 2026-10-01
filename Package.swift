// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EarshotCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "EarshotCore", targets: ["EarshotCore"]),
        .executable(name: "earshot-probe", targets: ["earshot-probe"]),
    ],
    targets: [
        .target(name: "EarshotCore"),
        .executableTarget(name: "earshot-probe", dependencies: ["EarshotCore"]),
        .testTarget(name: "EarshotCoreTests", dependencies: ["EarshotCore"]),
    ]
)
