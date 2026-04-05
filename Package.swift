// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ServiceManager",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ServiceManager",
            path: "Sources/ServiceManager",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ]),
            ]
        ),
    ]
)
