// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Switchel",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything: converters, tools, editors and the menu-bar app.
        .target(name: "SwitchelKit"),
        .executableTarget(name: "Switchel", dependencies: ["SwitchelKit"]),
        .testTarget(name: "SwitchelKitTests", dependencies: ["SwitchelKit"]),
    ]
)
