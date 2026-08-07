// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Uziq",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Uziq", targets: ["Uziq"])
    ],
    targets: [
        .executableTarget(
            name: "Uziq",
            path: "Sources/Uziq",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "UziqTests",
            dependencies: ["Uziq"],
            path: "Tests/UziqTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
