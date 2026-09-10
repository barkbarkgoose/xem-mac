// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "geenyan",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "geenyan",
            path: "Sources/geenyan",
            // AppKit app with hand-managed queue confinement in FileWatcher;
            // Swift 6's actor isolation adds churn without buying safety here.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
