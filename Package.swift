// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "XiangqiPilot",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "XiangqiPilot", targets: ["XiangqiPilotApp"])
    ],
    targets: [
        .target(
            name: "XiangqiCore"
        ),
        .executableTarget(
            name: "XiangqiPilotApp",
            dependencies: ["XiangqiCore"]
        ),
        .testTarget(
            name: "XiangqiCoreTests",
            dependencies: ["XiangqiCore"]
        ),
        .testTarget(
            name: "XiangqiPilotAppTests",
            dependencies: ["XiangqiPilotApp", "XiangqiCore"]
        )
    ]
)
