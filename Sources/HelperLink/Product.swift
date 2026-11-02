// The product's name, version and identifiers, and the directories it keeps its files in, for the app and the
// command alike.

import Foundation

public enum Product {
  // The one place the visible name is set; the command, the MCP server and the directories take it in lower case.
  public static let appName = "Backstage"
  public static let commandName = appName.lowercased()
  // The release version, also the app's CFBundleShortVersionString (`make app` reads it from here).
  public static let version = "0.2.0"
  // Persisted: macOS ties the Accessibility, Screen Recording and other grants to this id.
  public static let bundleIdentifier = "local.cua-mcp.helper"
  // The two latest macOS versions, on Apple silicon only.
  public static let minimumMacOS = 26
  public static let installedAppPath = "/Applications/\(appName).app"
  // Inside the bundle: the app's own executable, and the command next to it.
  public static let appExecutableName = appName
  public static let commandRelativePath = "Contents/Helpers/\(commandName)"
}

// The one directory the app and the command keep their files in: the app list, the activity log, the socket and the
// signing keychain. A test home takes its place.
public struct Directories: Sendable {
  public let config: String
  public let data: String
  public let state: String

  public init(home: String = NSHomeDirectory(), testHome: String? = nil) {
    let directory = testHome ?? home + "/Library/Application Support/" + Product.appName
    config = directory
    data = directory
    state = directory
  }

  public var socketPath: String { state + "/helper.sock" }
  public var approvalsPath: String { config + "/approvals.json" }
  public var decisionLogPath: String { state + "/decisions.jsonl" }
}

// Parents get the usual permissions, the directory itself only its owner's.
public func ensurePrivateDirectory(_ path: String) throws {
  let manager = FileManager.default
  try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try manager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  chmod(path, 0o700)
}
