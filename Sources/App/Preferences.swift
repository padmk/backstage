// The settings people change in the Backstage window, kept in the helper's own defaults.

import Foundation

enum Preferences {
  private static let menuBarKey = "showsMenuBarItem"
  private static let everyAppKey = "allowsEveryApp"
  private static let tabKey = "controlTab"
  private static let lockedWindowsKey = "worksInWindowsWhileLocked"

  // Only the copy in Applications keeps running, shows a menu bar item or starts at login, so test and
  // development copies elsewhere never do.
  static var isInstalledCopy: Bool { Bundle.main.bundlePath == "/Applications/\(Configuration.appName).app" }

  static var showsMenuBarItem: Bool {
    get { UserDefaults.standard.bool(forKey: menuBarKey) }
    set { UserDefaults.standard.set(newValue, forKey: menuBarKey) }
  }

  // Every app except those never available, without the list. Off by default.
  static var allowsEveryApp: Bool {
    get { UserDefaults.standard.bool(forKey: everyAppKey) }
    set { UserDefaults.standard.set(newValue, forKey: everyAppKey) }
  }

  // Screenshots and input by coordinates while the screen is locked, through private window server calls and
  // without verification. Off by default.
  static var worksInWindowsWhileLocked: Bool {
    get { UserDefaults.standard.bool(forKey: lockedWindowsKey) }
    set { UserDefaults.standard.set(newValue, forKey: lockedWindowsKey) }
  }

  static var lastTab: String? {
    get { UserDefaults.standard.string(forKey: tabKey) }
    set { UserDefaults.standard.set(newValue, forKey: tabKey) }
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
