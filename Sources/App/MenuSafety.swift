// Menu items no agent may use, in any app: the Apple menu (Restart, Shut Down, Log Out, System Settings), whose
// effects reach the whole Mac and which loginwindow, never available, would then own; and the Services and Share
// menus, which hand the app's content to other apps past the list of apps agents may use. Reading them is
// harmless; acting on them is refused on every route, since every action on an element passes through here.

import AppKit
import ApplicationServices

private let maxMenuDepth = 12

// The Share menu's title in English and in the language AppKit shows, since it has no identifier of its own.
private let shareTitles: Set<String> = {
  var titles: Set<String> = ["Share"]
  if let appKit = Bundle(identifier: "com.apple.AppKit") {
    for table in ["MenuCommands", "SharingServices", "Localizable"] {
      let localized = appKit.localizedString(forKey: "Share", value: "", table: table)
      if !localized.isEmpty, localized != "Share" { titles.insert(localized) }
    }
  }
  return titles
}()

// Why `element` may not be acted on, or nil. It belongs to the app's menu bar when one of its ancestors is.
func restrictedMenu(_ element: AXUIElement, in application: AXUIElement) -> String? {
  guard let bar = attribute(application, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) else { return nil }
  var chain = [element]
  var current = element
  while chain.count < maxMenuDepth, let parent = attribute(current, kAXParentAttribute).map({ $0 as! AXUIElement }) {
    if CFEqual(parent, bar) {
      let tops = (attribute(bar, kAXChildrenAttribute) as? [AXUIElement]) ?? []
      guard let top = chain.last, let index = tops.firstIndex(where: { CFEqual($0, top) }) else { return nil }
      if index == 0 { return "the Apple menu" }
      let items = chain.filter { stringAttribute($0, kAXRoleAttribute) == kAXMenuItemRole }
      // The app menu's only submenu is Services; an item inside it is a service.
      if index == 1, items.contains(where: hasSubmenu) {
        return "the Services menu"
      }
      if items.contains(where: { shareTitles.contains(stringAttribute($0, kAXTitleAttribute) ?? "") && hasSubmenu($0) }) {
        return "the Share menu"
      }
      return nil
    }
    chain.append(parent)
    current = parent
  }
  return nil
}

private func hasSubmenu(_ item: AXUIElement) -> Bool {
  !((attribute(item, kAXChildrenAttribute) as? [AXUIElement]) ?? []).isEmpty
}

func requireAllowedMenu(_ element: AXUIElement, app: AppIdentity) throws {
  let application = AXUIElementCreateApplication(app.pid)
  guard let menu = restrictedMenu(element, in: application) else { return }
  throw HelperError(code: "not_allowed", message: "Items in \(menu) are never available to agents: they act on the whole Mac or hand content to other apps. Ask the user to do it.")
}
