// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NimbusLevitonBar",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "NimbusLevitonBar", targets: ["NimbusLevitonBar"]),
    ],
    targets: [
        // The whole menu bar app. build.sh wraps the binary into "Nimbus Leviton Bar.app".
        .executableTarget(
            name: "NimbusLevitonBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
