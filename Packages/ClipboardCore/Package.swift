// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipboardCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ClipboardCore", targets: ["ClipboardCore"]),
    ],
    targets: [
        .target(name: "ClipboardCore"),
        .testTarget(
            name: "ClipboardCoreTests",
            dependencies: ["ClipboardCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
