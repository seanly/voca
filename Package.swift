// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Voca",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Voca",
            path: "Sources/Voca"
        )
    ]
)
