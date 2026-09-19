// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Blacksite",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BlacksiteCore", targets: ["BlacksiteCore"]),
        .executable(name: "BlacksiteMac", targets: ["BlacksiteMac"]),
    ],
    targets: [
        .target(name: "BlacksiteCore"),
        .executableTarget(
            name: "BlacksiteMac",
            dependencies: ["BlacksiteCore"],
            resources: [.copy("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("Metal"),
                .linkedFramework("MetalKit"), .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"), .linkedFramework("QuartzCore"),
            ]
        ),
        .testTarget(name: "BlacksiteCoreTests", dependencies: ["BlacksiteCore"]),
        .testTarget(name: "BlacksiteMacTests", dependencies: ["BlacksiteMac"]),
    ],
    swiftLanguageVersions: [.v5]
)
