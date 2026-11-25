// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacCaptions",
    platforms: [.macOS("26.4")],
    targets: [
        .executableTarget(
            name: "MacCaptions",
            path: "Sources/MacCaptions",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Embed an Info.plist so the bare binary can show permission prompts (microphone, system audio, speech).
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", "Sources/MacCaptions/Info.plist"])
            ]
        ),
    ]
)
