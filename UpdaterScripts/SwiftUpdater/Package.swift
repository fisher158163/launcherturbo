// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftUpdater",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "SwiftUpdater", targets: ["SwiftUpdater"])
    ],
    targets: [
        .executableTarget(
            name: "SwiftUpdater",
            linkerSettings: [
                .linkedLibrary("ncurses")
            ]
        )
    ]
)
