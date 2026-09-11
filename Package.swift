// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TerminalVelocity",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TerminalVelocity", targets: ["TerminalVelocity"])],
    targets: [
        .executableTarget(name: "TerminalVelocity"),
        .testTarget(name: "TerminalVelocityTests", dependencies: ["TerminalVelocity"])
    ]
)
