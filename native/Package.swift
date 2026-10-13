// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeroOOSNative",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "HeroOOS", targets: ["HeroOOSNative"]), .executable(name: "oos-state", targets: ["OOSCLI"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "OOSCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "OOSCLI", dependencies: ["OOSCore"]),
        .executableTarget(name: "HeroOOSNative", dependencies: ["OOSCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "HeroOOSNativeTests", dependencies: ["HeroOOSNative"])
    ],
    swiftLanguageModes: [.v5]
)
