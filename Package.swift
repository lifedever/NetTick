// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NetTick",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NetTick",
            path: "Sources/NetTick",
            // 语言模式停在 v5：NetworkStatistics 的回调是 C block，跑在自己的串行队列上，
            // v6 的严格并发检查在这里只会逼出一堆 nonisolated(unsafe) 噪音（同 TabFlick）。
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
