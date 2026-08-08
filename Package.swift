// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Uziq",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Uziq", targets: ["Uziq"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/jellyfin/jellyfin-sdk-swift.git",
            exact: "3.0.0"
        ),
        .package(
            url: "https://github.com/Peter-Schorn/SpotifyAPI.git",
            revision: "610365935e4d1a5ce1f05e748600b3d793932abf"
        )
    ],
    targets: [
        .executableTarget(
            name: "Uziq",
            dependencies: [
                .product(name: "JellyfinAPI", package: "jellyfin-sdk-swift"),
                .product(name: "SpotifyAPI", package: "SpotifyAPI")
            ],
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
            dependencies: [
                "Uziq",
                .product(name: "JellyfinAPI", package: "jellyfin-sdk-swift")
            ],
            path: "Tests/UziqTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
