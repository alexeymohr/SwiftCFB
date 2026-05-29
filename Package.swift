// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftCFB",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        .library(name: "SwiftCFB", targets: ["SwiftCFB"]),
        .executable(name: "cfb-dump", targets: ["cfb-dump"]),
    ],
    targets: [
        .target(name: "SwiftCFB"),
        .executableTarget(
            name: "cfb-dump",
            dependencies: ["SwiftCFB"]
        ),
        .testTarget(
            name: "SwiftCFBTests",
            dependencies: ["SwiftCFB"]
        ),
    ]
)
