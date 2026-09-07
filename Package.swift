// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PastePal",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "PastePal", targets: ["PastePal"])],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "2.4.0")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "PastePalLocalization", resources: [.process("Resources")]),
        .target(name: "ClipboardCore", dependencies: ["CSQLite", "PastePalLocalization"]),
        .executableTarget(
            name: "PastePal",
            dependencies: ["ClipboardCore", "KeyboardShortcuts", "PastePalLocalization"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore"]),
        .testTarget(name: "PastePalTests", dependencies: ["PastePal"])
    ],
    swiftLanguageModes: [.v5]
)
