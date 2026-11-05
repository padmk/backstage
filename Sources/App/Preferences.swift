// The settings people change in the Backstage window, kept in the helper's own defaults.

import Foundation

enum Preferences {
  private static let menuBarKey = "showsMenuBarItem"
  private static let tabKey = "controlTab"

  // Only the copy in Applications keeps running, shows a menu bar item or starts at login, so test and
  // development copies elsewhere never do.
  static var isInstalledCopy: Bool { Bundle.main.bundlePath == "/Applications/\(Configuration.appName).app" }

  static var showsMenuBarItem: Bool {
    get { UserDefaults.standard.bool(forKey: menuBarKey) }
    set { UserDefaults.standard.set(newValue, forKey: menuBarKey) }
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
