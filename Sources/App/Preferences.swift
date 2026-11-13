// The settings people change in the Backstage window, in settings.json next to the app list.

import Foundation
import HelperLink

enum Preferences {
  private static let menuBarKey = "showsMenuBarItem"
  private static let everyAppKey = "allowsEveryApp"
  private static let tabKey = "controlTab"
  private static let lockedWindowsKey = "worksInWindowsWhileLocked"
  private static let askedAppDataKey = "askedAppData"
  private static let computersKey = "allowedComputers"

  private static let lock = NSLock()
  private static var path: String { Configuration.directories.settingsPath }

  // Read on every use, so an edit to the file applies to the next request as the switches in the window do.
  private static func read() -> JSON {
    guard let data = FileManager.default.contents(atPath: path),
      // Unreadable settings are the defaults, as on a first start; the next change writes them anew.
      let settings = try? JSONSerialization.jsonObject(with: data) as? JSON else { return [:] }
    return settings
  }

  private static func value<T>(_ key: String) -> T? { lock.withLock { read()[key] as? T } }

  private static func set(_ key: String, _ value: Any) {
    lock.withLock {
      var settings = read()
      settings[key] = value
      do {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try writePrivateFile(data, to: path)
      } catch {
        // The window reads the settings again, so the switch shows the value that stayed.
        appLog.error("The setting \(key, privacy: .public) could not be saved: \(String(describing: error), privacy: .public)")
      }
    }
  }

  // Only the copy in Applications keeps running, shows a menu bar item or starts at login, so test and
  // development copies elsewhere never do.
  static var isInstalledCopy: Bool { Product.appLocations.contains(Bundle.main.bundlePath) }

  static var showsMenuBarItem: Bool {
    get { value(menuBarKey) ?? false }
    set { set(menuBarKey, newValue) }
  }

  // Every app except those never available, without the list. Off by default.
  static var allowsEveryApp: Bool {
    get { value(everyAppKey) ?? false }
    set { set(everyAppKey, newValue) }
  }

  // Screenshots and input by coordinates while the screen is locked, through private window server calls and
  // without verification. Off by default.
  static var worksInWindowsWhileLocked: Bool {
    get { value(lockedWindowsKey) ?? false }
    set { set(lockedWindowsKey, newValue) }
  }

  // The apps whose data macOS has been asked about, by bundle id; see appDataState.
  static var askedAppData: Set<String> {
    get { Set(value(askedAppDataKey) ?? [String]()) }
    set { set(askedAppDataKey, newValue.sorted()) }
  }

  // The other Macs agents may reach with `computer`, by the name ssh reaches each under; see ComputerList.
  static var allowedComputers: [String] {
    get { (value(computersKey) ?? [String]()).filter { ComputerName.problem(with: $0) == nil } }
    set { set(computersKey, newValue) }
  }

  static var lastTab: String? {
    get { value(tabKey) }
    set { set(tabKey, newValue ?? NSNull()) }
  }
  // With either on, the helper stays running instead of stopping when no agent has used it for a while.
  static var keepsRunning: Bool {
    guard isInstalledCopy else { return false }
    if showsMenuBarItem { return true }
    switch LaunchAtLogin.state {
    case .on, .needsApproval: return true
    case .off, .unavailable: return false
    }
  }
}
