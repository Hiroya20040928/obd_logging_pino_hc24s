// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PinoCoreValidation",
    platforms: [.macOS(.v13)],
    products: [.library(name: "PinoCore", targets: ["PinoCore"])],
    targets: [
        .target(name: "PinoCore"),
        .testTarget(name: "PinoCoreTests", dependencies: ["PinoCore"])
    ]
)
