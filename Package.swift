// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Poogle",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Poogle", targets: ["Poogle"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3"
        ),
        .executableTarget(
            name: "Poogle",
            dependencies: ["CSQLite"],
            path: "Sources/Poogle",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "PoogleTests",
            dependencies: ["Poogle"]
        )
    ]
)
