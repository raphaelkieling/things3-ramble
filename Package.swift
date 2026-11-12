// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Things3Ramble",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Ramble"),
    ]
)
