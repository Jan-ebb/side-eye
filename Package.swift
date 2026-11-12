// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Relay", targets: ["Relay"])],
    targets: [.executableTarget(name: "Relay")]
)
