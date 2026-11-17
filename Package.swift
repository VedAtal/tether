// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tether",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/VedAtal/swift-app-kit.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "Tether",
            dependencies: [.product(name: "SwiftAppKit", package: "swift-app-kit")],
            path: "Sources/Tether"
        )
    ]
)
