// swift-tools-version: 6.2
// Backstage: a helper app that operates Mac apps in the background, and the command that serves MCP to agents
// and sets the app up. `make app` assembles the two into Backstage.app.

import PackageDescription

// The compiler checks the shared code and the command for data races, and warnings fail their build. Set
// ALLOW_WARNINGS=1 to build anyway, as the Homebrew formula does, so a newer Xcode's new warnings never stop an install.
let allowsWarnings = !(Context.environment["ALLOW_WARNINGS"] ?? "").isEmpty
let strict: [SwiftSetting] = [.swiftLanguageMode(.v5), .enableUpcomingFeature("StrictConcurrency")]
  + (allowsWarnings ? [] : [.treatAllWarnings(as: .error)])

let package = Package(
  name: "Backstage",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "Backstage", targets: ["App"]),
    .executable(name: "backstage-tool", targets: ["Tool"]),
  ],
  targets: [
    // What the app and the command share: the product's name and version, its directories, line framing and
    // build identity.
    .target(name: "HelperLink", swiftSettings: strict),
    .executableTarget(name: "App", dependencies: ["HelperLink"], swiftSettings: [.swiftLanguageMode(.v6)] + (allowsWarnings ? [] : [.treatAllWarnings(as: .error)])),
    .executableTarget(name: "Tool", dependencies: ["HelperLink"], swiftSettings: strict),
    .testTarget(name: "ToolTests", dependencies: ["Tool", "HelperLink"], exclude: [], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "AppTests", dependencies: ["App", "HelperLink"], swiftSettings: [.swiftLanguageMode(.v5)]),
  ]
)
