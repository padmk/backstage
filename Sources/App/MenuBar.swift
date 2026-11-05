// The menu bar item, off by default: Backstage's state, the agents connected now, the approved apps, and a way
// to open the window. Opening the menu never brings the app forward; only Open Backstage does.

import AppKit

private let menuAppLimit = 10
private let menuIconSize: CGFloat = 16

final class MenuBarItem: NSObject, NSMenuDelegate {
  static let shared = MenuBarItem()
  private var item: NSStatusItem?

  // Shows or removes the item to match the setting; only the installed copy shows one.
  func update() {
    onMain {
      let wanted = Preferences.isInstalledCopy && Preferences.showsMenuBarItem
      if wanted, item == nil {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = Configuration.appName
        let image = NSImage(systemSymbolName: "theatermasks", accessibilityDescription: Configuration.appName)
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
      } else if !wanted, let item {
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
      }
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    var missing: [String] = []
    if !AXIsProcessTrusted() { missing.append(ControlTexts.accessibility) }
    if !CGPreflightScreenCaptureAccess() { missing.append(ControlTexts.screenRecording) }
    let status = missing.isEmpty ? ControlTexts.ready : ControlTexts.needs(missing.joined(separator: " and "))
    menu.addItem(entry(status, symbol: missing.isEmpty ? "checkmark.circle" : "exclamationmark.triangle",
                       action: missing.isEmpty ? nil : #selector(openPermissions)))
    let clients = connectedClients()
    menu.addItem(entry(clients.isEmpty ? ControlTexts.noAgents : ControlTexts.connected(clients), symbol: "person.2", action: nil))

    menu.addItem(.separator())
    menu.addItem(.sectionHeader(title: ControlTexts.appsHeading))
    let apps = approvedApps()
    for row in apps.prefix(menuAppLimit) {
      let app = entry(row.name, symbol: nil, action: #selector(openApps))
      if let icon = appIcon(path: nil, bundleIdentifier: row.bundleId)?.copy() as? NSImage {
        icon.size = NSSize(width: menuIconSize, height: menuIconSize)
        app.image = icon
      }
      menu.addItem(app)
    }
    if apps.isEmpty { menu.addItem(entry(ControlTexts.noApps, symbol: nil, action: nil)) }
    if apps.count > menuAppLimit { menu.addItem(entry(ControlTexts.andMore(apps.count - menuAppLimit), symbol: nil, action: #selector(openApps))) }

    menu.addItem(.separator())
    menu.addItem(entry(ControlTexts.openBackstage, symbol: nil, action: #selector(openWindow)))
  }

  private func entry(_ title: String, symbol: String?, action: Selector?) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = action == nil ? nil : self
    item.isEnabled = action != nil
    if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    return item
  }

  @objc private func openPermissions() { showControlWindow(tab: .permissions) }
  @objc private func openApps() { showControlWindow(tab: .apps) }
  @objc private func openWindow() { showControlWindow() }
}
