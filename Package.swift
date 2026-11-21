// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AdFreeAndroidLauncher",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AdFreeAndroidLauncher", targets: ["AdFreeAndroidLauncher"])],
    targets: [.executableTarget(name: "AdFreeAndroidLauncher")]
)
