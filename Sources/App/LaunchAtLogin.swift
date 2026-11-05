// Starting Backstage when the user logs in, through the system's Login Items. macOS holds the setting, and the
// user can change it in System Settings, so it is always read from there rather than stored here.

import AppKit
import ServiceManagement

enum LoginState: Equatable {
  case on, off, needsApproval, unavailable
}

enum LaunchAtLogin {
  static var state: LoginState {
    guard Preferences.isInstalledCopy else { return .unavailable }
    switch SMAppService.mainApp.status {
    case .enabled: return .on
    case .requiresApproval: return .needsApproval
    default: return .off
    }
  }

  static func set(_ on: Bool) throws {
    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
  }

  static func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

  // A launch at login opens the app without --background, which would otherwise show the window in front.
  static func launchedAtLogin() -> Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication else { return false }
    return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
  }
}
