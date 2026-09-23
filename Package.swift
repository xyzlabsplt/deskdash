// swift-tools-version: 6.0
// deskdash: a glanceable dashboard for the Wokyis dock's 5" screen. No dependencies beyond the macOS SDK.
import PackageDescription

let package = Package(
    name: "deskdash",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "deskdash", path: "Sources/deskdash")
    ]
)
