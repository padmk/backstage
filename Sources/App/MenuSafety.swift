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

// How long a check may read before it refuses, apart from the search for refused shortcuts, which has its own.
private let menuCheckSeconds = 2.0

// The reads of the menu check. Unlike `attribute`, they tell an attribute the element lacks from one the app could
// not give, and each one checks the check's deadline before and after it, since one call can wait for an app that
// does not answer: a check that could not read all it needs refuses, because what it missed may be a refused item.
struct MenuReader {
  typealias Copy = (AXUIElement, String) -> AttributeRead
  let appName: String
  let deadline: Date
  private let copy: Copy

  init(appName: String, seconds: TimeInterval = menuCheckSeconds, copy: @escaping Copy = readAttribute) {
    self.appName = appName
    deadline = Date().addingTimeInterval(seconds)
    self.copy = copy
  }

  func value(_ element: AXUIElement, _ name: String) throws -> AnyObject? {
    try requireTime()
    let read = copy(element, name)
    try requireTime()
    switch read {
    case .value(let value): return value
    case .absent: return nil
    case .unreadable(let result): throw unreadable(result)
    }
  }

  func string(_ element: AXUIElement, _ name: String) throws -> String? {
    guard let value = try value(element, name) else { return nil }
    guard let text = value as? String else { throw unexpected(name) }
    return text.isEmpty ? nil : text
  }

  func bool(_ element: AXUIElement, _ name: String) throws -> Bool {
    guard let value = try value(element, name) else { return false }
    guard let flag = value as? Bool else { throw unexpected(name) }
    return flag
  }

  func element(_ element: AXUIElement, _ name: String) throws -> AXUIElement? {
    guard let value = try value(element, name) else { return nil }
    guard let found = cfCast(value, to: AXUIElement.self, typeID: AXUIElementGetTypeID()) else { throw unexpected(name) }
    return found
  }

  func elements(_ element: AXUIElement, _ name: String = kAXChildrenAttribute) throws -> [AXUIElement] {
    guard let value = try value(element, name) else { return [] }
    let list = value as? [AnyObject]
    let found = list?.compactMap { cfCast($0, to: AXUIElement.self, typeID: AXUIElementGetTypeID()) }
    guard let list, let found, found.count == list.count else { throw unexpected(name) }
    return found
  }

  private func requireTime() throws {
    guard Date() < deadline else {
      throw HelperError(code: "timeout", message: "\(appName)'s menus could not be read in time to check that this is not an item of the Apple, Services or Share menu, so nothing was done. Try again in a moment.")
    }
  }

  private func unreadable(_ result: AXError) -> HelperError {
    switch result {
    case .invalidUIElement:
      return HelperError(code: "stale_element", message: "An element or menu the check needed went away while it was read, so nothing was done. Read the window state again.")
    case .apiDisabled:
      return axFailure(result, "checking the menus")
    case .cannotComplete:
      return HelperError(code: "timeout", message: "\(appName) did not answer while its menus were checked for items of the Apple, Services or Share menu, so nothing was done. Try again in a moment.")
    default:
      return HelperError(code: "action_failed", message: "\(appName)'s menus could not be read to check for items of the Apple, Services or Share menu (AX error \(result.rawValue)), so nothing was done.")
    }
  }

  private func unexpected(_ name: String) -> HelperError {
    HelperError(code: "action_failed", message: "\(appName) answered \(name) with something other than expected while its menus were checked, so nothing was done.")
  }
}

// Why `element` may not be acted on, or nil: an item in the Apple menu, or under a Services or Share submenu,
// whether in the menu bar or in a context menu, or a Share button in a toolbar. The way up ends at the menu bar, a
// window or the app, above which nothing decides.
func restrictedMenu(_ element: AXUIElement, in application: AXUIElement, reader: MenuReader) throws -> String? {
  var chain = [element]
  var reachedBar = false
  while chain.count < maxMenuDepth, let parent = try reader.element(chain[chain.count - 1], kAXParentAttribute) {
    let role = try reader.string(parent, kAXRoleAttribute)
    if role == kAXMenuBarRole {
      reachedBar = true
      break
    }
    if role == kAXWindowRole || role == kAXApplicationRole { break }
    chain.append(parent)
  }
  if try isShareButton(element, chain: chain, reader: reader) { return "the Share button" }
  var submenuTitles: [String] = []
  for item in chain.reversed() where try reader.string(item, kAXRoleAttribute) == kAXMenuItemRole && !reader.elements(item).isEmpty {
    submenuTitles.append(try reader.string(item, kAXTitleAttribute) ?? "")
  }
  var topIndex: Int?
  if reachedBar, let bar = try reader.element(application, kAXMenuBarAttribute), let top = chain.last {
    topIndex = try reader.elements(bar).firstIndex { CFEqual($0, top) }
  }
  return refusedMenu(topIndex: topIndex, submenuTitles: submenuTitles)
}

// A toolbar's Share button has no identifier of its own either: it is told by its role, AppKit's title for Share
// and its place in a toolbar.
private func isShareButton(_ element: AXUIElement, chain: [AXUIElement], reader: MenuReader) throws -> Bool {
  guard [kAXButtonRole, kAXMenuButtonRole].contains(try reader.string(element, kAXRoleAttribute) ?? "") else { return false }
  let label = try reader.string(element, kAXDescriptionAttribute) ?? reader.string(element, kAXTitleAttribute) ?? ""
  guard label != "Services", handOffTitles.contains(label) else { return false }
  return try chain.dropFirst().contains { try reader.string($0, kAXRoleAttribute) == kAXToolbarRole }
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
  try requireAllowedMenu(element, in: AXUIElementCreateApplication(app.pid), reader: MenuReader(appName: app.name))
}

func requireAllowedMenu(_ element: AXUIElement, in application: AXUIElement, reader: MenuReader) throws {
  guard let menu = try restrictedMenu(element, in: application, reader: reader) else { return }
  throw refusal(menu)
}

private let pointRoles: Set<String> = [kAXMenuItemRole, kAXMenuBarItemRole, kAXButtonRole, kAXMenuButtonRole]
// A menu item's or button's text and image lie a level or two below it.
private let pointAncestorDepth = 3

// What lies under a point on the screen, checked when it is part of a menu or a button, since a click there acts
// on it as a press would. The hit may be a part of the item, such as its image or text, so its ancestors up to the
// window are looked at too.
func requireAllowedPoint(_ point: CGPoint, app: AppIdentity) throws {
  let application = AXUIElementCreateApplication(app.pid)
  let reader = MenuReader(appName: app.name)
  var found: AXUIElement?
  guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &found) == .success,
    let found else {
    try requireNoMenuUnder(point, app: app, application: application, reader: reader)
    return
  }
  // A hit on the window or the app itself, or on an element outside any window, says no more than a failed one.
  let foundRole = try reader.string(found, kAXRoleAttribute) ?? ""
  if [kAXWindowRole, kAXApplicationRole].contains(foundRole) {
    return try requireNoMenuUnder(point, app: app, application: application, reader: reader)
  }
  var element = found
  for _ in 0..<pointAncestorDepth {
    let role = try reader.string(element, kAXRoleAttribute) ?? ""
    if pointRoles.contains(role) { return try requireAllowedMenu(element, in: application, reader: reader) }
    guard role != kAXWindowRole, let parent = try reader.element(element, kAXParentAttribute) else {
      // An element outside any window may be part of a menu.
      if role != kAXWindowRole { try requireNoMenuUnder(point, app: app, application: application, reader: reader) }
      return
    }
    element = parent
  }
  // No menu item, button or window within reach above the hit: what it belongs to is unknown.
  try requireNoMenuUnder(point, app: app, application: application, reader: reader)
}

// When Accessibility cannot tell what is under a point, as in many custom views and web content, or gives only the
// window, the click goes on unless one of the app's menus is open or one of its windows at menu level covers the
// point: the item there cannot be checked then.
private func requireNoMenuUnder(_ point: CGPoint, app: AppIdentity, application: AXUIElement, reader: MenuReader) throws {
  let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
  guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
    throw HelperError(code: "action_failed", message: "The window server's list of windows could not be read to check what lies under that point, so nothing was clicked.")
  }
  let menuWindow = windows.contains { info in
    guard (info[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == app.pid,
      (info[kCGWindowLayer as String] as? Int ?? 0) >= menuLevel,
      let bounds = info[kCGWindowBounds as String] as? NSDictionary,
      let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
    return frame.contains(point)
  }
  if try !shownMenus(of: application, reader: reader).isEmpty {
    throw HelperError(code: "not_allowed", message: "\(app.name) has a menu open and what lies under that point cannot be read, so nothing was clicked: it could be an item in the Apple, Services or Share menu. Close the menu with press_key escape, or choose its item with press.")
  }
  if menuWindow {
    throw HelperError(code: "not_allowed", message: "A window of \(app.name) at menu level covers that point and what lies there cannot be read, so nothing was clicked: it could be an item in the Apple, Services or Share menu. Use press on an element instead, or wait until that window is gone.")
  }
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
  // shortcutText writes what parse reads; a text it cannot read names no key an agent can send.
  return refused.first { (try? KeyCombination.parse($0.shortcut)) == combination }?.menu
}

private let confirmingKeys: Set<String> = ["return", "space"]

// A key the app's menus answer to: a shortcut of a refused item, or a key that confirms the selected item of an
// open menu when that item is refused. Other keys go to the focused view and are not looked at.
func requireAllowedKey(_ combination: KeyCombination, app: AppIdentity) throws {
  guard confirmingKeys.contains(combination.key) || combination.isShortcut else { return }
  if let menu = refusedMenu(for: combination, among: []) { throw refusal(menu, shortcut: combination) }
  let application = try applicationElement(app)
  try requireAllowedKey(combination, application: application, appName: app.name)
}

func requireAllowedKey(_ combination: KeyCombination, application: AXUIElement, appName: String,
                       copy: @escaping MenuReader.Copy = readAttribute, shortcutSeconds: TimeInterval = refusedSearchSeconds) throws {
  if confirmingKeys.contains(combination.key) {
    let reader = MenuReader(appName: appName, copy: copy)
    if let item = try selectedMenuItem(of: application, reader: reader) { try requireAllowedMenu(item, in: application, reader: reader) }
  }
  guard combination.isShortcut else { return }
  if let menu = refusedMenu(for: combination, among: []) { throw refusal(menu, shortcut: combination) }
  let refused = try refusedShortcuts(of: application, reader: MenuReader(appName: appName, seconds: shortcutSeconds, copy: copy))
  if let menu = refusedMenu(for: combination, among: refused) { throw refusal(menu, shortcut: combination) }
}

let refusedSearchSeconds = 1.0

// The shortcuts of the app's refused items, read only where they can be: the whole Apple menu, and in full the
// submenus that `refusedMenu` refuses from their title among the direct items of each top-level menu (every
// submenu of the app menu, which is Services, and a Services or Share submenu anywhere). Allowed commands are not
// read. A Share submenu nested inside another submenu is not looked for; such items carry no shortcuts in practice.
// An app without a menu bar has no such items; one whose menu bar or menus cannot be read in full is refused.
private func refusedShortcuts(of application: AXUIElement, reader: MenuReader) throws -> [(shortcut: String, menu: String)] {
  guard let bar = try reader.element(application, kAXMenuBarAttribute) else { return [] }
  var found: [(shortcut: String, menu: String)] = []
  // Every item under `parent`, an item or a menu bar item whose child is its menu.
  func collect(_ parent: AXUIElement, menu: String, depth: Int) throws {
    guard depth < maxMenuDepth else {
      throw HelperError(code: "timeout", message: "\(reader.appName)'s Apple, Services and Share menus nest too deep to check that the key is not one of their shortcuts, so it was not sent.")
    }
    for list in try reader.elements(parent) {
      for item in try reader.elements(list) {
        if let shortcut = try shortcutText(of: item, reading: reader.value) { found.append((shortcut: shortcut, menu: menu)) }
        try collect(item, menu: menu, depth: depth + 1)
      }
    }
  }
  for (index, top) in try reader.elements(bar).enumerated() {
    if let menu = refusedMenu(topIndex: index, submenuTitles: []) {
      try collect(top, menu: menu, depth: 1)
      continue
    }
    for list in try reader.elements(top) {
      for item in try reader.elements(list) {
        let title = try reader.string(item, kAXTitleAttribute) ?? ""
        guard let menu = refusedMenu(topIndex: index, submenuTitles: [title]) else { continue }
        try collect(item, menu: menu, depth: 2)
      }
    }
  }
  return found
}

// Typed text goes out as keys. In an open menu letters select an item by its name and a space confirms the selection,
// so text with a space is refused while the app shows a menu, or while it cannot be told whether it shows one.
func postAllowedText(_ text: String, app: AppIdentity) throws {
  if text.contains(" ") {
    try requireNoMenuShown(by: AXUIElementCreateApplication(app.pid), appName: app.name)
  }
  try postText(text, pid: app.pid)
}

func requireNoMenuShown(by application: AXUIElement, appName: String, copy: @escaping MenuReader.Copy = readAttribute) throws {
  guard try shownMenus(of: application, reader: MenuReader(appName: appName, copy: copy)).isEmpty else {
    throw HelperError(code: "not_allowed", message: "\(appName) has a menu open, where a space confirms the selected item. Close the menu first, or choose its item with press.")
  }
}

// The menus the app shows: context menus, and the menu of the menu bar item that is open.
private func shownMenus(of application: AXUIElement, reader: MenuReader) throws -> [AXUIElement] {
  var menus: [AXUIElement] = []
  for child in try reader.elements(application) where try reader.string(child, kAXRoleAttribute) == kAXMenuRole {
    menus.append(child)
  }
  if let bar = try reader.element(application, kAXMenuBarAttribute) {
    for top in try reader.elements(bar) where try reader.bool(top, kAXSelectedAttribute) {
      menus += try reader.elements(top)
    }
  }
  return menus
}

// The item an open menu has selected, in the menu bar or a context menu, deepest submenu first.
private func selectedMenuItem(of application: AXUIElement, reader: MenuReader) throws -> AXUIElement? {
  var menus = try shownMenus(of: application, reader: reader)
  var selected: AXUIElement?
  for _ in 0..<maxMenuDepth {
    var next: AXUIElement?
    search: for menu in menus {
      for item in try reader.elements(menu) where try reader.bool(item, kAXSelectedAttribute) {
        next = item
        break search
      }
    }
    guard let item = next else { break }
    selected = item
    menus = try reader.elements(item)
  }
  return selected
}
