// Background helper that reads and operates Mac apps. It runs as its own app, started through LaunchServices, so
// that macOS ties Accessibility, Screen Recording and the other grants to it. It serves line-delimited JSON on a
// Unix socket in a directory only this user can open, and decides every approval itself.

import AppKit
import ApplicationServices
import HelperLink

@main
enum HelperMain {
  static func main() {
    let arguments = CommandLine.arguments
    if arguments.contains(permissionStatesArgument) {
      printPermissionStates()
      return
    }
    if let index = arguments.firstIndex(of: Product.renderWindowArgument), arguments.indices.contains(index + 1) {
      exit(renderControlWindow(into: arguments[index + 1]) ? 0 : 1)
    }
    for directory in [Configuration.configHome, Configuration.stateHome] {
      try? ensurePrivateDirectory(directory)
    }

    // The system-wide timeout applies to every element, so one hung app cannot hold a request for long.
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2)

    // Read before anything can replace the executable, so the app reports the build it runs.
    _ = Configuration.build
    startServer()

    let application = NSApplication.shared
    let delegate = AppDelegate(arguments: arguments)
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { application.run() }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let arguments: [String]

  init(arguments: [String]) { self.arguments = arguments }

  func applicationDidFinishLaunching(_ notification: Notification) {
    MenuBarItem.shared.update()
    PointerActivity.start()
    // Clients start the helper with --background, and a launch at login has to stay unseen too.
    let tab = arguments.firstIndex(of: Product.tabArgument).flatMap { arguments.indices.contains($0 + 1) ? ControlTab(rawValue: arguments[$0 + 1]) : nil }
    if !arguments.contains(Product.backgroundArgument), !LaunchAtLogin.launchedAtLogin() { showControlWindow(tab: tab) }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showControlWindow()
    return true
  }
}
