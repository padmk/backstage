// Background helper that reads and operates Mac apps with public Apple APIs. It runs as its own app so
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

// Read before anything can replace the executable, so the app reports the build it runs.
_ = ownBuildIdentity
startServer()

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.run()
