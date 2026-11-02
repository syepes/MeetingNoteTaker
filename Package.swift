// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeetingNoteTaker",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "MeetingNoteTaker", targets: ["MeetingNoteTaker"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2", traits: []),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0")
    ],
    targets: [
        .target(name: "AudioDSP", publicHeadersPath: "include"),
        .target(name: "MeetingCore", dependencies: ["AudioDSP", .product(name: "FluidAudio", package: "FluidAudio"), .product(name: "Markdown", package: "swift-markdown")]),
        .executableTarget(name: "MeetingNoteTaker", dependencies: ["MeetingCore"]),
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"])
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
