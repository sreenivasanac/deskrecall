// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DeskRecall",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DeskRecall", path: "Sources/DeskRecall")
    ]
)
