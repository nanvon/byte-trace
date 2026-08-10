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
        .executable(name: "ByteTraceApp", targets: ["ByteTraceApp"])
    ],
    targets: [
        .target(
            name: "ByteTraceCore",
            resources: [
                .copy("Resources/public_suffix_list.dat")
            ],
            linkerSettings: [.linkedFramework("SystemConfiguration")]
        ),
        .executableTarget(
            name: "ByteTraceApp",
            dependencies: ["ByteTraceCore"],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "ByteTraceProbe",
            dependencies: ["ByteTraceCore"]
        ),
        .testTarget(
            name: "ByteTraceCoreTests",
            dependencies: ["ByteTraceCore"]
        )
    ]
)
