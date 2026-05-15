// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Disco",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "Disco",
            path: "Sources",
            resources: [
                .copy("../Resources/emoji.json")
            ],
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-disable-reflection-metadata"])
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
