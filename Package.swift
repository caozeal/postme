// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "postme",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "postme", targets: ["Postme"])
    ],
    targets: [
        .executableTarget(
            name: "Postme",
            path: "Sources/Postme",
            swiftSettings: [
                // v1 先用 Swift 5 语言模式,避开严格并发带来的摩擦;
                // 代码结构已按 v6 准备(store 全部 @MainActor),后续可一行切换。
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "PostmeTests",
            dependencies: ["Postme"],
            path: "Tests/PostmeTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
