// The product's name, version and identifiers, and the directories it keeps its files in, for the app and the
// command alike.

import Foundation

public enum Product {
  // The one place the visible name is set; the command, the MCP server and the directories take it in lower case.
  public static let appName = "Backstage"
  public static let commandName = appName.lowercased()
  // The release version, also the app's CFBundleShortVersionString (`make app` reads it from here).
  public static let version = "0.2.0"
  // Persisted: macOS ties the Accessibility, Screen Recording and other grants to this id, and the settings live
  // in its defaults domain. Changing it costs every user those grants once.
  public static let bundleIdentifier = "app.foreverbeta.backstage"
  // The two latest macOS versions, on Apple silicon only.
  public static let minimumMacOS = 26
  // Where the app is installed: /Applications, or ~/Applications for an account that cannot write there.
  public static let appLocations = ["/Applications/\(appName).app", NSHomeDirectory() + "/Applications/\(appName).app"]
  public static var installedAppPath: String { appLocations.first { FileManager.default.fileExists(atPath: $0) } ?? appLocations[0] }
  // Inside the bundle: the app's own executable, and the command next to it.
  public static let appExecutableName = appName
  public static let commandRelativePath = "Contents/Helpers/\(commandName)"
}

// The XDG base directories at their default places. The XDG_* variables are not read: the app also starts from
// launchd, at login or from the Finder, without the shell's environment, and has to find the same files. A test
// home holds all three.
public struct Directories: Sendable {
  public let config: String
  public let data: String
  public let state: String

  public init(home: String = NSHomeDirectory(), testHome: String? = nil) {
    if let testHome {
      config = testHome
      data = testHome
      state = testHome
    } else {
      config = home + "/.config/" + Product.commandName
      data = home + "/.local/share/" + Product.commandName
      state = home + "/.local/state/" + Product.commandName
    }
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
