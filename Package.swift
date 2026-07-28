// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitHubMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GitHubMonitor", targets: ["GitHubMonitor"])
    ],
    targets: [
        .executableTarget(name: "GitHubMonitor")
    ]
)
