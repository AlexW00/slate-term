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
        .executable(name: "slate-layout-launcher", targets: ["SlateLayoutLauncher"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.5.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5"),
    ],
    targets: [
        .target(name: "SlateTermCore"),
        .executableTarget(name: "SlateLayoutLauncher"),
        .target(name: "SlateTermIPC", dependencies: ["SlateTermCore"]),
        .target(name: "SlateArchive", linkerSettings: [.linkedLibrary("archive")]),
        .target(name: "SlateTermSettings", dependencies: [
            "SlateTermCore", "SlateArchive", .product(name: "TOMLDecoder", package: "TOMLDecoder"),
        ]),
        .executableTarget(name: "SlateTermCLI", dependencies: [
            "SlateTermCore", "SlateTermIPC", "SlateTermSettings", .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .target(name: "SlateTermTestSupport", dependencies: ["SlateTermCore"], path: "Tests/SlateTermTestSupport"),
        .testTarget(name: "SlateTermCoreTests", dependencies: ["SlateTermCore", "SlateTermTestSupport"]),
        .testTarget(name: "SlateTermCLITests", dependencies: ["SlateTermCLI", "SlateTermCore"]),
        .testTarget(name: "SlateTermIPCTests", dependencies: ["SlateTermIPC", "SlateTermCore"]),
        .testTarget(name: "SlateTermSettingsTests", dependencies: ["SlateTermSettings", "SlateTermCore", "SlateTermTestSupport"]),
    ]
)
