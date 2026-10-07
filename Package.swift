// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "VideoCutEditor",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "VideoCutEditor",
            targets: ["VideoCutEditor"]
        ),
    ],
    targets: [
        .target(
            name: "VideoCutEditor",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .testTarget(
            name: "VideoCutEditorTests",
            dependencies: ["VideoCutEditor"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
    ]
)
