// Menu items no agent may use, in any app: the Apple menu (Restart, Shut Down, Log Out, System Settings), whose
// effects reach the whole Mac and which loginwindow, never available, would then own; and the Services and Share
// menus, which hand the app's content to other apps past the list of apps agents may use. Reading them is
// harmless; acting on them is refused on every route: by element, by a point on an open menu, by a key that
// confirms an open menu's selection, and by a shortcut that is theirs.

import AppKit
import ApplicationServices

private let maxMenuDepth = 12

// The Services and Share menus' titles in English and in the language AppKit shows, since they have no identifier
// of their own; a context menu carries them too, away from the menu bar.
let handOffTitles: Set<String> = {
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

// Why an item may not be acted on, from where it sits: `topIndex` is its menu's place in the menu bar (nil in a
// context menu), and `submenuTitles` are the titles of the items with a submenu on its path from the menu bar,
// itself included when it opens one.
func refusedMenu(topIndex: Int?, submenuTitles: [String]) -> String? {
  if let handOff = submenuTitles.last(where: handOffTitles.contains) {
    return handOff == "Share" ? "the Share menu" : "a Services or Share menu"
  }
  if topIndex == 0 { return "the Apple menu" }
  // The app menu's only submenu is Services; an item inside it is a service.
  if topIndex == 1, !submenuTitles.isEmpty { return "the Services menu" }
  return nil
}

// Why `element` may not be acted on, or nil: an item in the Apple menu, or under a Services or Share submenu,
// whether in the menu bar or in a context menu, or a Share button in a toolbar.
func restrictedMenu(_ element: AXUIElement, in application: AXUIElement) -> String? {
  var chain = [element]
  var reachedBar = false
  while chain.count < maxMenuDepth, let parent = attribute(chain[chain.count - 1], kAXParentAttribute).map({ $0 as! AXUIElement }) {
    if stringAttribute(parent, kAXRoleAttribute) == kAXMenuBarRole {
      reachedBar = true
      break
    }
    chain.append(parent)
  }
  if isShareButton(element, chain: chain) { return "the Share button" }
  let submenuTitles = chain.reversed().filter { stringAttribute($0, kAXRoleAttribute) == kAXMenuItemRole && hasSubmenu($0) }
    .map { stringAttribute($0, kAXTitleAttribute) ?? "" }
  var topIndex: Int?
  if reachedBar, let bar = attribute(application, kAXMenuBarAttribute).map({ $0 as! AXUIElement }), let top = chain.last {
    topIndex = ((attribute(bar, kAXChildrenAttribute) as? [AXUIElement]) ?? []).firstIndex { CFEqual($0, top) }
  }
  return refusedMenu(topIndex: topIndex, submenuTitles: submenuTitles)
}

// A toolbar's Share button has no identifier of its own either: it is told by its role, AppKit's title for Share
// and its place in a toolbar.
private func isShareButton(_ element: AXUIElement, chain: [AXUIElement]) -> Bool {
  guard [kAXButtonRole, kAXMenuButtonRole].contains(stringAttribute(element, kAXRoleAttribute) ?? "") else { return false }
  let label = stringAttribute(element, kAXDescriptionAttribute) ?? stringAttribute(element, kAXTitleAttribute) ?? ""
  guard label != "Services", handOffTitles.contains(label) else { return false }
  return chain.dropFirst().contains { stringAttribute($0, kAXRoleAttribute) == kAXToolbarRole }
}

private func hasSubmenu(_ item: AXUIElement) -> Bool {
  !((attribute(item, kAXChildrenAttribute) as? [AXUIElement]) ?? []).isEmpty
}

// `shortcut` names the combination when a key, not an element, was refused.
private func refusal(_ menu: String, shortcut: KeyCombination? = nil) -> HelperError {
  let what = menu.hasSuffix("button")
    ? "The Share button is never available to agents: it hands content to other apps."
    : "Items in \(menu) are never available to agents: they act on the whole Mac or hand content to other apps."
  let key = shortcut.map { "\($0.text) is the shortcut of an item in \(menu). " } ?? ""
  return HelperError(code: "not_allowed", message: key + what + " Ask the user to do it.")
}

func requireAllowedMenu(_ element: AXUIElement, app: AppIdentity) throws {
  let application = AXUIElementCreateApplication(app.pid)
  guard let menu = restrictedMenu(element, in: application) else { return }
  throw refusal(menu)
}

private let pointRoles: Set<String> = [kAXMenuItemRole, kAXMenuBarItemRole, kAXButtonRole, kAXMenuButtonRole]

// What lies under a point on the screen, checked when it is part of a menu or a button, since a click there acts
// on it as a press would. The hit may be a part of the item, such as its image or text, so its ancestors up to the
// window are looked at too.
func requireAllowedPoint(_ point: CGPoint, app: AppIdentity) throws {
  let application = AXUIElementCreateApplication(app.pid)
  var found: AXUIElement?
  guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &found) == .success,
    let found else {
    try requireNoMenuUnder(point, app: app, application: application)
    return
  }
  // A hit on the window or the app itself, or on an element outside any window, says no more than a failed one.
  let foundRole = stringAttribute(found, kAXRoleAttribute) ?? ""
  if [kAXWindowRole, kAXApplicationRole].contains(foundRole) {
    return try requireNoMenuUnder(point, app: app, application: application)
  }
  var element = found
  for _ in 0..<maxMenuDepth {
    let role = stringAttribute(element, kAXRoleAttribute) ?? ""
    if pointRoles.contains(role) { return try requireAllowedMenu(element, app: app) }
    if role == kAXWindowRole { return }
    guard let parent = attribute(element, kAXParentAttribute).map({ $0 as! AXUIElement }) else { break }
    element = parent
  }
  try requireNoMenuUnder(point, app: app, application: application)
}

// When Accessibility cannot tell what is under a point, as in many custom views and web content, or gives only the
// window, the click goes on
// unless one of the app's menus is open or one of its windows at menu level covers the point: the item there cannot
// be checked then.
private func requireNoMenuUnder(_ point: CGPoint, app: AppIdentity, application: AXUIElement) throws {
  let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
  let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
  let menuWindow = windows.contains { info in
    guard (info[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == app.pid,
      (info[kCGWindowLayer as String] as? Int ?? 0) >= menuLevel,
      let bounds = info[kCGWindowBounds as String] as? NSDictionary,
      let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
    return frame.contains(point)
  }
  guard menuWindow || !shownMenus(of: application).isEmpty else { return }
  throw HelperError(code: "not_allowed", message: "\(app.name) has a menu open and what lies under that point cannot be read, so nothing was clicked: it could be an item in the Apple, Services or Share menu. Close the menu with press_key escape, or choose its item with press.")
}

// Every click and drag goes out through these, wherever its point came from (coordinates or an element's
// center), so what lies under each point is checked right before the events are posted.
func postAllowedClick(at point: CGPoint, app: AppIdentity, target: PointerTarget, count: Int, style: ClickStyle = ClickStyle()) throws {
  try requireAllowedPoint(point, app: app)
  try postClick(at: point, target: target, pid: app.pid, count: count, style: style)
}

func postAllowedForegroundClick(at point: CGPoint, app: AppIdentity, window: AXUIElement, count: Int, style: ClickStyle) throws {
  try requireAllowedPoint(point, app: app)
  try postForegroundClick(at: point, window: window, pid: app.pid, count: count, style: style)
}

func postAllowedDrag(from start: CGPoint, to end: CGPoint, app: AppIdentity, target: PointerTarget) throws {
  try requireAllowedPoint(start, app: app)
  try requireAllowedPoint(end, app: app)
  try postDrag(from: start, to: end, target: target, pid: app.pid)
}

// The Apple menu's shortcuts as macOS defines them: Log Out, Log Out without asking, Lock Screen, Force Quit, and
// force quitting the app in front.
let appleMenuShortcuts: [KeyCombination] = [
  KeyCombination(modifiers: [.shift, .cmd], key: "q"),
  KeyCombination(modifiers: [.alt, .shift, .cmd], key: "q"),
  KeyCombination(modifiers: [.ctrl, .cmd], key: "q"),
  KeyCombination(modifiers: [.alt, .cmd], key: "escape"),
  KeyCombination(modifiers: [.alt, .shift, .cmd], key: "escape"),
]

// The refused menu a combination is the shortcut of, among the Apple menu's own and those of the app's refused
// items, given as each item's shortcut text and menu.
func refusedMenu(for combination: KeyCombination, among refused: [(shortcut: String, menu: String)]) -> String? {
  if appleMenuShortcuts.contains(combination) { return "the Apple menu" }
  return refused.first { (try? KeyCombination.parse($0.shortcut)) == combination }?.menu
}

private let confirmingKeys: Set<String> = ["return", "space"]

// A key the app's menus answer to: a shortcut of a refused item, or a key that confirms the selected item of an
// open menu when that item is refused. Other keys go to the focused view and are not looked at.
func requireAllowedKey(_ combination: KeyCombination, app: AppIdentity) throws {
  if confirmingKeys.contains(combination.key), let item = selectedMenuItem(of: AXUIElementCreateApplication(app.pid)) {
    try requireAllowedMenu(item, app: app)
  }
  guard combination.isShortcut else { return }
  if let menu = refusedMenu(for: combination, among: []) { throw refusal(menu, shortcut: combination) }
  let refused: [(shortcut: String, menu: String)]
  do {
    refused = try refusedShortcuts(app: app)
  } catch let error as HelperError where error.code == "window_not_found" {
    return
  }
  if let menu = refusedMenu(for: combination, among: refused) { throw refusal(menu, shortcut: combination) }
}

private let refusedSearchSeconds = 1.0

// The shortcuts of the app's refused items, read only where they can be: the whole Apple menu, and in full the
// submenus that `refusedMenu` refuses from their title among the direct items of each top-level menu (every
// submenu of the app menu, which is Services, and a Services or Share submenu anywhere). Allowed commands are not read. A Share
// submenu nested inside another submenu is not looked for; such items carry no shortcuts in practice.
private func refusedShortcuts(app: AppIdentity) throws -> [(shortcut: String, menu: String)] {
  let application = try applicationElement(app)
  guard let bar = attribute(application, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) else {
    throw HelperError(code: "window_not_found", message: "\(app.name) has no menu bar.")
  }
  let started = Date()
  var found: [(shortcut: String, menu: String)] = []
  var cut = false
  func children(_ element: AXUIElement) -> [AXUIElement] {
    guard Date().timeIntervalSince(started) < refusedSearchSeconds else {
      cut = true
      return []
    }
    return (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
  }
  // Every item under `parent`, an item or a menu bar item whose child is its menu.
  func collect(_ parent: AXUIElement, menu: String, depth: Int) {
    guard depth < maxMenuDepth else {
      cut = true
      return
    }
    for list in children(parent) {
      for item in children(list) {
        if let shortcut = shortcutText(of: item) { found.append((shortcut: shortcut, menu: menu)) }
        collect(item, menu: menu, depth: depth + 1)
      }
    }
  }
  for (index, top) in children(bar).enumerated() {
    if let menu = refusedMenu(topIndex: index, submenuTitles: []) {
      collect(top, menu: menu, depth: 1)
      continue
    }
    for list in children(top) {
      for item in children(list) {
        let title = stringAttribute(item, kAXTitleAttribute) ?? ""
        guard let menu = refusedMenu(topIndex: index, submenuTitles: [title]) else { continue }
        collect(item, menu: menu, depth: 2)
      }
    }
  }
  guard !cut else {
    throw HelperError(code: "timeout", message: "\(app.name)'s Apple, Services and Share menus could not be read in time to check that the key is not one of their shortcuts, so it was not sent. Try again in a moment.")
  }
  return found
}

// Typed text goes out as keys. In an open menu letters select an item by its name and a space confirms the selection,
// so text with a space is refused while the app shows a menu.
func postAllowedText(_ text: String, app: AppIdentity) throws {
  if text.contains(" "), !shownMenus(of: AXUIElementCreateApplication(app.pid)).isEmpty {
    throw HelperError(code: "not_allowed", message: "\(app.name) has a menu open, where a space confirms the selected item. Close the menu first, or choose its item with press.")
  }
  try postText(text, pid: app.pid)
}

// The menus the app shows: context menus, and the menu of the menu bar item that is open.
private func shownMenus(of application: AXUIElement) -> [AXUIElement] {
  var menus = openMenus(of: application)
  if let bar = attribute(application, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) {
    for top in (attribute(bar, kAXChildrenAttribute) as? [AXUIElement]) ?? [] where boolAttribute(top, kAXSelectedAttribute) {
      menus += (attribute(top, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
  }
  return menus
}

// The item an open menu has selected, in the menu bar or a context menu, deepest submenu first.
private func selectedMenuItem(of application: AXUIElement) -> AXUIElement? {
  var menus = shownMenus(of: application)
  var selected: AXUIElement?
  for _ in 0..<maxMenuDepth {
    guard let item = menus.lazy.flatMap({ (attribute($0, kAXChildrenAttribute) as? [AXUIElement]) ?? [] })
      .first(where: { boolAttribute($0, kAXSelectedAttribute) }) else { break }
    selected = item
    menus = (attribute(item, kAXChildrenAttribute) as? [AXUIElement]) ?? []
  }
  return selected
}
