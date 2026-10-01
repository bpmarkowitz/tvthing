// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TVThingKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TVThingKit", targets: ["TVThingKit"])
    ],
    targets: [
        .target(name: "TVThingKit"),
        // Headless engine for developing the Car Thing app without the Mac UI.
        .executableTarget(name: "tvthing-server", dependencies: ["TVThingKit"]),
        .testTarget(name: "TVThingKitTests", dependencies: ["TVThingKit"])
    ]
)
