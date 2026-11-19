// swift-tools-version:6.2
import PackageDescription

// 命令行工具环境没有 Swift Testing 宏插件,验证由 tingjian-check 可执行目标完成。
let package = Package(
    name: "Tingjian",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "TingjianCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Tingjian", dependencies: ["TingjianCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "tingjian-check", dependencies: ["TingjianCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
