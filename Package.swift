// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SlateTerm",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SlateTermCore", targets: ["SlateTermCore"]),
        .library(name: "SlateTermIPC", targets: ["SlateTermIPC"]),
        .library(name: "SlateTermSettings", targets: ["SlateTermSettings"]),
        .executable(name: "slate-term", targets: ["SlateTermCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.5.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5"),
    ],
    targets: [
        .target(name: "SlateTermCore"),
        .target(name: "SlateTermIPC", dependencies: ["SlateTermCore"]),
        .target(name: "SlateTermSettings", dependencies: [
            "SlateTermCore", .product(name: "TOMLDecoder", package: "TOMLDecoder"),
        ]),
        .executableTarget(name: "SlateTermCLI", dependencies: [
            "SlateTermCore", "SlateTermIPC", "SlateTermSettings", .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "SlateTermCoreTests", dependencies: ["SlateTermCore"]),
        .testTarget(name: "SlateTermCLITests", dependencies: ["SlateTermCLI", "SlateTermCore"]),
        .testTarget(name: "SlateTermIPCTests", dependencies: ["SlateTermIPC", "SlateTermCore"]),
        .testTarget(name: "SlateTermSettingsTests", dependencies: ["SlateTermSettings", "SlateTermCore"]),
    ]
)
