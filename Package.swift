// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteDictateHelper",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "RemoteDictateCore", targets: ["RemoteDictateCore"]),
        .executable(name: "remote-dictate-helper", targets: ["RemoteDictateHelper"])
    ],
    targets: [
        .target(name: "RemoteDictateCore"),
        .executableTarget(name: "RemoteDictateHelper", dependencies: ["RemoteDictateCore"])
    ]
)
