// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "StockDashboard",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MarketCore"),
        .executableTarget(name: "StockDashboard", dependencies: ["MarketCore"]),
        .executableTarget(
            name: "StockDashboardWidget",
            dependencies: ["MarketCore"],
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
    ]
)
