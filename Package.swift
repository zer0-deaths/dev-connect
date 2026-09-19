// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DevConnect",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DevConnect", type: .dynamic, targets: ["DevConnect"])
    ],
    dependencies: [
        .package(url: "https://gitlab.com/droppyformac1/droppykit.git", from: "1.6.0")
    ],
    targets: [
        .target(
            name: "DevConnect",
            dependencies: [.product(name: "DroppyKit", package: "droppykit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DevConnectHarness",
            dependencies: [
                "DevConnect",
                .product(name: "DroppyKitHarness", package: "droppykit")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
