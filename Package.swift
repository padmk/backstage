// swift-tools-version: 6.2
// Backstage: a helper app that operates Mac apps in the background, and the command that serves MCP to agents
// and sets the app up. `make app` assembles the two into Backstage.app.

import PackageDescription

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
    .target(name: "HelperLink", swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "App", dependencies: ["HelperLink"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "Tool", dependencies: ["HelperLink"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "ToolTests", dependencies: ["Tool", "HelperLink"], exclude: [], swiftSettings: [.swiftLanguageMode(.v5)]),
  ]
)
