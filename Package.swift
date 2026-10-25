// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NBAGlass",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NBAGlass", targets: ["NBAGlass"]),
        .library(name: "NBAGlassCore", targets: ["NBAGlassCore"]),
    ],
    targets: [
        .target(name: "NBAGlassCore"),
        .executableTarget(name: "NBAGlass", dependencies: ["NBAGlassCore"]),
        .testTarget(name: "NBAGlassCoreTests", dependencies: ["NBAGlassCore"]),
    ]
)
