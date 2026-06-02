// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "logister-ios",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .tvOS(.v15),
        .watchOS(.v8)
    ],
    products: [
        .library(name: "Logister", targets: ["Logister"])
    ],
    targets: [
        .target(name: "Logister"),
        .testTarget(name: "LogisterTests", dependencies: ["Logister"])
    ]
)
