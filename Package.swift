// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GymKitProbe",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "GymKitProbe",
            targets: ["GymKitProbe"]
        ),
    ],
    targets: [
        .target(name: "GymKitProbe"),
    ],
    // CoreBluetooth delegates predate Swift 6 strict concurrency.
    swiftLanguageModes: [.v5]
)
