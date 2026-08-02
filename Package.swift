// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ByteTrace",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ByteTraceCore", targets: ["ByteTraceCore"]),
        .executable(name: "ByteTraceProbe", targets: ["ByteTraceProbe"]),
        .executable(name: "ByteTraceConnectionProbe", targets: ["ByteTraceConnectionProbe"]),
        .executable(name: "ByteTraceApp", targets: ["ByteTraceApp"]),
        .executable(name: "ByteTraceIconLab", targets: ["ByteTraceIconLab"])
    ],
    targets: [
        .target(name: "ByteTraceCore"),
        .executableTarget(
            name: "ByteTraceApp",
            dependencies: ["ByteTraceCore"]
        ),
        .executableTarget(name: "ByteTraceIconLab"),
        .executableTarget(
            name: "ByteTraceProbe",
            dependencies: ["ByteTraceCore"]
        ),
        .executableTarget(
            name: "ByteTraceConnectionProbe",
            dependencies: ["ByteTraceCore"]
        ),
        .testTarget(
            name: "ByteTraceCoreTests",
            dependencies: ["ByteTraceCore"]
        )
    ]
)
