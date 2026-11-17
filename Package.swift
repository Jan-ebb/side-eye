// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SideEye",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SideEye", targets: ["SideEye"])],
    targets: [.executableTarget(name: "SideEye")]
)
