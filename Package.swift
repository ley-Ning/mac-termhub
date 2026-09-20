// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TermHub",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "TermHubCore", targets: ["TermHubCore"]),
        .library(name: "TermHubUI", targets: ["TermHubUI"]),
        .executable(name: "TermHub", targets: ["TermHub"])
    ],
    dependencies: [
        // Citadel 本地化（0.12.1 + 线程安全补丁，见 Packages/Citadel 内注释）
        .package(path: "Packages/Citadel"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.20.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "TermHubCore",
            dependencies: [
                .product(name: "Citadel", package: "Citadel")
            ],
            path: "Packages/TermHubKit/Sources/TermHubCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "TermHubUI",
            dependencies: [
                .target(name: "TermHubCore"),
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Packages/TermHubKit/Sources/TermHubUI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TermHub",
            dependencies: [
                .target(name: "TermHubCore"),
                .target(name: "TermHubUI")
            ],
            path: "App/Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TermHubSmoke",
            dependencies: [
                .target(name: "TermHubCore"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Citadel", package: "Citadel")
            ],
            path: "Smoke",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TermHubMCP",
            dependencies: [
                .target(name: "TermHubCore"),
                .product(name: "Citadel", package: "Citadel")
            ],
            path: "MCP",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
