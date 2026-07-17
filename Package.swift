// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "osaurus-messages",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "osaurus-messages", type: .dynamic, targets: ["osaurus_messages"])
    ],
    dependencies: [
        .package(url: "https://github.com/osaurus-ai/osaurus-plugin-sdk.git", exact: "1.0.0")
    ],
    targets: [
        .target(
            name: "osaurus_messages",
            dependencies: [
                .product(name: "OsaurusPluginABI", package: "osaurus-plugin-sdk"),
                .product(name: "OsaurusPluginKit", package: "osaurus-plugin-sdk"),
            ],
            path: "Sources/osaurus_messages"
        ),
        .testTarget(
            name: "osaurus_messagesTests",
            dependencies: [
                "osaurus_messages",
                .product(name: "OsaurusPluginTestSupport", package: "osaurus-plugin-sdk"),
            ],
            path: "Tests/osaurus_messagesTests"
        ),
    ]
)
