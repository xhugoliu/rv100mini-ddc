// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DDCInputHotkeys",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ddc-input-hotkeys", targets: ["DDCInputHotkeys"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/waydabber/AppleSiliconDDC.git",
            revision: "97af3818b9803e51412fb50cac1506db1d73b5bf"
        )
    ],
    targets: [
        .executableTarget(
            name: "DDCInputHotkeys",
            dependencies: ["AppleSiliconDDC"],
            linkerSettings: [
                .linkedFramework("Carbon")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
