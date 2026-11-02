// Background helper that reads and operates Mac apps. It runs as its own app so
// that macOS ties Accessibility and Screen Recording to it. It serves line-delimited JSON on a Unix socket
// in a directory only this user can open, and decides every approval itself.

import AppKit
import HelperLink
import ApplicationServices

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--home"), arguments.indices.contains(index + 1) {
  Configuration.home = arguments[index + 1]
}

// The system-wide timeout applies to every element, so one hung app cannot hold a request for long.
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2)

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    if !arguments.contains("--background") { showControlWindow() }
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
