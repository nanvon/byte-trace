// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ByteTrace",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "ByteTraceCore", targets: ["ByteTraceCore"]),
        .executable(name: "ByteTraceProbe", targets: ["ByteTraceProbe"]),
        .executable(name: "ByteTraceApp", targets: ["ByteTraceApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(
            name: "ByteTraceCore",
            linkerSettings: [.linkedFramework("SystemConfiguration")]
        ),
        .executableTarget(
            name: "ByteTraceApp",
            dependencies: [
                "ByteTraceCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
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
