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
        .executable(name: "Decanter", targets: ["Decanter"]),
        .executable(name: "GPUKeepalive", targets: ["GPUKeepalive"])
    ],
    targets: [
        .executableTarget(
            name: "Decanter",
            path: "Sources/Decanter"
        ),
        // Bundled helper (Contents/MacOS/gpukeepalive) — see its own doc comment for why this
        // needs to be a separate process rather than code inside Decanter itself: it must keep
        // submitting to the GPU on its own schedule for as long as the watched game runs,
        // independent of anything the main app is doing.
        .executableTarget(
            name: "GPUKeepalive",
            path: "Sources/GPUKeepalive"
        ),
        .testTarget(
            name: "DecanterTests",
            dependencies: ["Decanter"],
            path: "Tests/DecanterTests"
        )
    ]
)
