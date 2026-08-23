// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NimbusLevitonBar",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "NimbusLevitonBar", targets: ["NimbusLevitonBar"]),
    ],
    dependencies: [
        // Ours, MIT, no dependencies of its own: the GitHub-release auto-updater. Pinned by
        // Package.resolved — a new tag reaches this app only when someone bumps it here.
        .package(url: "https://github.com/njoubert/nimbus-updater.git", from: "1.0.0"),
    ],
    targets: [
        // The whole menu bar app. build.sh wraps the binary into "Nimbus Leviton Bar.app".
        .executableTarget(
            name: "NimbusLevitonBar",
            dependencies: [
                .product(name: "NimbusUpdater", package: "nimbus-updater"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
