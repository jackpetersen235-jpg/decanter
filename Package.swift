// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Decanter",
    platforms: [
        // Deployment target. Your machine runs Tahoe (macOS 26) but v14 keeps the
        // app buildable/runnable on a wider range of Apple Silicon Macs.
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Decanter", targets: ["Decanter"])
    ],
    targets: [
        .executableTarget(
            name: "Decanter",
            path: "Sources/Decanter"
        ),
        .testTarget(
            name: "DecanterTests",
            dependencies: ["Decanter"],
            path: "Tests/DecanterTests"
        )
    ]
)
