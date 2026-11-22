// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DeskRecall",
    platforms: [.macOS(.v14)],
    dependencies: [
        // In-app updates. The one dependency: installing a new version over a running app safely is not a few lines.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "DeskRecall",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/DeskRecall",
            // The app bundle carries Sparkle.framework in Contents/Frameworks (scripts/build-app.sh puts it there);
            // a bare build finds it next to the binary.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                           "-Xlinker", "-rpath", "-Xlinker", "@loader_path"])]
        )
    ]
)
