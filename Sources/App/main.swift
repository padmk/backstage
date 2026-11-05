// Background helper that reads and operates Mac apps. It runs as its own app so
// that macOS ties Accessibility and Screen Recording to it. It serves line-delimited JSON on a Unix socket
// in a directory only this user can open, and decides every approval itself.

import AppKit
import HelperLink
import ApplicationServices

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--home"), arguments.indices.contains(index + 1) {
  Configuration.configHome = arguments[index + 1]
  Configuration.stateHome = arguments[index + 1]
}
for directory in [Configuration.configHome, Configuration.stateHome] {
  try? FileManager.default.createDirectory(atPath: (directory as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  chmod(directory, 0o700)
}

// The system-wide timeout applies to every element, so one hung app cannot hold a request for long.
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2)

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    MenuBarItem.shared.update()
    // Clients start the helper with --background, and a launch at login has to stay unseen too.
    let tab = arguments.firstIndex(of: "--tab").flatMap { arguments.indices.contains($0 + 1) ? ControlTab(rawValue: arguments[$0 + 1]) : nil }
    if !arguments.contains("--background"), !LaunchAtLogin.launchedAtLogin() { showControlWindow(tab: tab) }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showControlWindow()
    return true
  }
}

// Read before anything can replace the executable, so the app reports the build it runs.
_ = ownBuildIdentity
startServer()

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
