// swift-tools-version:5.10
import PackageDescription

// A standalone package on purpose: nothing in the app's Package.swift refers to it, so
// `swift build` at the repo root neither builds nor sees this. Phase 0 of docs/lg-tv-plan.md
// is a go/no-go gate, and a gate that can break the shipping app is not a gate.
let package = Package(
    name: "lgtv",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "lgtv", targets: ["lgtv"]),
    ],
    targets: [
        .executableTarget(name: "lgtv"),
    ]
)
