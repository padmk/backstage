// Menu items no agent may use, in any app: the Apple menu (Restart, Shut Down, Log Out, System Settings), whose
// effects reach the whole Mac and which loginwindow, never available, would then own; and the Services and Share
// menus, which hand the app's content to other apps past the list of apps agents may use. Reading them is
// harmless; acting on them is refused on every route, since every action on an element passes through here.

import AppKit
import ApplicationServices

private let maxMenuDepth = 12

// The Services and Share menus' titles in English and in the language AppKit shows, since they have no identifier
// of their own; a context menu carries them too, away from the menu bar.
private let handOffTitles: Set<String> = {
  var titles: Set<String> = ["Share", "Services"]
  if let appKit = Bundle(identifier: "com.apple.AppKit") {
    for key in ["Share", "Services"] {
      for table in ["MenuCommands", "SharingServices", "Localizable", "ServicesMenu"] {
        let localized = appKit.localizedString(forKey: key, value: "", table: table)
        if !localized.isEmpty, localized != key { titles.insert(localized) }
      }
    }
  }
  return titles
}()

// Why `element` may not be acted on, or nil: an item in the Apple menu, or under a Services or Share submenu,
// whether in the menu bar or in a context menu.
func restrictedMenu(_ element: AXUIElement, in application: AXUIElement) -> String? {
  var chain = [element]
  var current = element
  while chain.count < maxMenuDepth, let parent = attribute(current, kAXParentAttribute).map({ $0 as! AXUIElement }) {
    chain.append(parent)
    current = parent
  }
  let items = chain.filter { stringAttribute($0, kAXRoleAttribute) == kAXMenuItemRole && hasSubmenu($0) }
  if let handOff = items.first(where: { handOffTitles.contains(stringAttribute($0, kAXTitleAttribute) ?? "") }) {
    return stringAttribute(handOff, kAXTitleAttribute) == "Share" ? "the Share menu" : "a Services or Share menu"
  }
  guard let bar = attribute(application, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) else { return nil }
  chain = [element]
  current = element
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
