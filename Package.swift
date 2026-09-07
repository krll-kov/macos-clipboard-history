// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "ClipHistory",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(
      name: "ClipHistory",
      path: "Sources/ClipHistory",
      swiftSettings: [.swiftLanguageMode(.v5)],
      linkerSettings: [.linkedLibrary("sqlite3")]
    )
  ]
)
