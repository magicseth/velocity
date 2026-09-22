// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TerminalVelocity",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TerminalVelocity", targets: ["TerminalVelocity"])],
    dependencies: [
        // Julia's subscription client — the same package + version Julia.app uses
        // (apps/mac/project.yml). Commands addressed to this Mac arrive by subscription;
        // nothing here polls.
        .package(url: "https://github.com/get-convex/convex-swift", from: "0.8.1")
    ],
    targets: [
        .executableTarget(name: "TerminalVelocity", dependencies: [.product(name: "ConvexMobile", package: "convex-swift")]),
        .testTarget(name: "TerminalVelocityTests", dependencies: ["TerminalVelocity"])
    ]
)
