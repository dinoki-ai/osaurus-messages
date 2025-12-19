// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "osaurus-messages",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "osaurus-messages", type: .dynamic, targets: ["osaurus_messages"])
    ],
    targets: [
        .target(
            name: "osaurus_messages",
            path: "Sources/osaurus_messages"
        )
    ]
)