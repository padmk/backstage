// An app's menu bar as a list of commands with their shortcuts, and running one by its path or shortcut. Almost
// everything an app can do is in its menus, so this tells an agent what any app offers without exploring its
// window, and keeps working when an app changes its layout. Menus are never opened on screen and shortcuts are
// never typed: commands run by pressing their item through Accessibility.

import AppKit
import ApplicationServices

private let defaultMaxCommands = 300
private let maxDepth = 6
private let listSeconds = 3.0

// AXMenuItemCmdModifiers: Command is implied unless its "no command" bit is set.
private let shiftBit = 1, optionBit = 2, controlBit = 4, noCommandBit = 8

// Keys a shortcut can name by virtual key code rather than by character.
private let namedKeys: [Int: String] = [
  36: "return", 48: "tab", 49: "space", 51: "delete", 53: "escape", 117: "forward_delete", 115: "home", 119: "end",
  116: "page_up", 121: "page_down", 123: "left", 124: "right", 125: "down", 126: "up",
  122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
]

struct MenuCommand {
  let path: [String]
  let element: AXUIElement

  var joinedPath: String { path.joined(separator: " > ") }
  var shortcut: String? { shortcutText(of: element) }
}

struct MenuBarRead {
  var commands: [MenuCommand] = []
  var truncated = false
}

func shortcutText(of item: AXUIElement) -> String? {
  let modifiers = (attribute(item, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue ?? 0
  var key = (attribute(item, "AXMenuItemCmdChar") as? String)?.lowercased() ?? ""
  if key.isEmpty, let code = (attribute(item, "AXMenuItemCmdVirtualKey") as? NSNumber)?.intValue { key = namedKeys[code] ?? "" }
  guard !key.isEmpty else { return nil }
  var parts: [String] = []
  if modifiers & controlBit != 0 { parts.append("ctrl") }
  if modifiers & optionBit != 0 { parts.append("alt") }
  if modifiers & shiftBit != 0 { parts.append("shift") }
  if modifiers & noCommandBit == 0 { parts.append("cmd") }
  return (parts + [key]).joined(separator: "+")
}

// Every command in the app's menu bar, depth first, without opening a menu: items AppKit fills only while a menu
// is open (Open Recent, some Window lists) can be missing, and those the app validates on opening can show a
// stale enabled state. The Apple menu and the Services and Share menus are left out, since they are never
// available. `topMenu` reads only the menu bar's menus with that title, when there is one.
func menuCommands(app: AppIdentity, topMenu: String? = nil) throws -> MenuBarRead {
  let application = try applicationElement(app)
  guard let bar = attribute(application, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) else {
    throw HelperError(code: "window_not_found", message: "\(app.name) has no menu bar.")
  }
  var read = MenuBarRead()
  let started = Date()
  func walk(_ menuParent: AXUIElement, path: [String], topIndex: Int, submenuTitles: [String], depth: Int) {
    guard depth < maxDepth else {
      read.truncated = true
      return
    }
    for menu in (attribute(menuParent, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
      for item in (attribute(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        guard Date().timeIntervalSince(started) < listSeconds else {
          read.truncated = true
          return
        }
        let title = stringAttribute(item, kAXTitleAttribute) ?? ""
        guard !title.isEmpty else { continue }
        let itemPath = path + [title]
        let children = (attribute(item, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        let titles = children.isEmpty ? submenuTitles : submenuTitles + [title]
        if refusedMenu(topIndex: topIndex, submenuTitles: titles) != nil { continue }
        if !children.isEmpty {
          walk(item, path: itemPath, topIndex: topIndex, submenuTitles: titles, depth: depth + 1)
        } else {
          read.commands.append(MenuCommand(path: itemPath, element: item))
        }
      }
    }
  }
  let tops = Array(((attribute(bar, kAXChildrenAttribute) as? [AXUIElement]) ?? []).enumerated())
  let titled = topMenu.map { wanted in tops.filter { normalized(stringAttribute($0.element, kAXTitleAttribute) ?? "") == wanted } } ?? []
  for (index, top) in titled.isEmpty ? tops : titled {
    guard !read.truncated else { break }
    if refusedMenu(topIndex: index, submenuTitles: []) != nil { continue }
    walk(top, path: [stringAttribute(top, kAXTitleAttribute) ?? ""], topIndex: index, submenuTitles: [], depth: 1)
  }
  return read
}

private func checked(_ item: AXUIElement) -> Bool? {
  guard let mark = attribute(item, "AXMenuItemMarkChar") as? String else { return false }
  return !mark.isEmpty
}

private func appIsActive(_ app: AppIdentity) -> Bool {
  onMain { NSRunningApplication(processIdentifier: app.pid)?.isActive ?? false }
}

private let keyWindowNote = "Commands that act on the current document or selection are disabled while the app is in the background, because it has no key window."

func listMenuCommands(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  let max = min(Swift.max(params["max"] as? Int ?? defaultMaxCommands, 1), 2000)
  let query = (params["query"] as? String)?.lowercased()
  let enabledOnly = params["enabled_only"] as? Bool == true
  let read = try menuCommands(app: app)
  var listed: [JSON] = []
  var more = read.truncated
  for command in read.commands {
    let enabled = boolAttribute(command.element, kAXEnabledAttribute)
    if enabledOnly, !enabled { continue }
    let shortcut = command.shortcut
    if let query, !command.joinedPath.lowercased().contains(query), shortcut?.contains(query) != true { continue }
    guard listed.count < max else {
      more = true
      break
    }
    var entry: JSON = ["path": command.joinedPath, "enabled": enabled,
                       "element": session.table.number(for: command.element, pid: app.pid, shownToAgent: true)]
    if let shortcut { entry["shortcut"] = shortcut }
    if let mark = checked(command.element), mark { entry["checked"] = true }
    listed.append(entry)
  }
  var result: JSON = ["app": app.name, "commands": listed, "truncated": more, "omitted": ["Apple menu", "Services", "Share"]]
  if !appIsActive(app) { result["note"] = keyWindowNote + " Enabled states are as the app last set them." }
  return result
}

private func normalized(_ text: String) -> String {
  text.lowercased().replacingOccurrences(of: "...", with: "…").trimmingCharacters(in: .whitespaces)
}

// The one command a path or a shortcut names. A path can leave out its menus when the last title is unique.
private func resolveCommand(_ all: [MenuCommand], params: JSON) throws -> MenuCommand {
  let matches: [MenuCommand]
  let asked: String
  if let path = params["command"] as? String {
    asked = path
    let wanted = path.split(separator: ">").map { normalized(String($0)) }
    matches = all.filter { command in
      let titles = command.path.map(normalized)
      return titles.count >= wanted.count && Array(titles.suffix(wanted.count)) == wanted
    }
  } else if let key = params["shortcut"] as? String {
    asked = key
    let wanted = try KeyCombination.parse(key)
    matches = all.filter { command in command.shortcut.flatMap { try? KeyCombination.parse($0) } == wanted }
  } else {
    throw HelperError(code: "invalid_request", message: "Give command (a path such as File > Export…) or shortcut (such as cmd+shift+s).")
  }
  if matches.count == 1 { return matches[0] }
  if matches.isEmpty {
    // Whole words in common, so "Log Out" does not suggest "Zoom Out" for its "out" alone when better ones exist.
    let words = Set(asked.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
    let titleWords = { (command: MenuCommand) in Set(command.joinedPath.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)) }
    let close = all.map { ($0, words.intersection(titleWords($0)).count) }.filter { $0.1 > 0 && $0.1 * 2 >= words.count }
      .sorted { $0.1 > $1.1 }.prefix(5).map { $0.0.joinedPath }
    throw HelperError(code: "not_found", message: "No menu command matches \(asked)." + (close.isEmpty ? " list_menu_commands lists them." : " Closest: \(close.joined(separator: "; ")).") )
  }
  throw HelperError(code: "ambiguous", message: "\(matches.count) commands match \(asked): \(matches.prefix(8).map(\.joinedPath).joined(separator: "; ")). Give more of the path.")
}

// Read again just before pressing, so a command disabled since the list is refused rather than pressed in vain.
func runMenuCommand(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  // A path that starts with a menu's title is looked for in that menu alone, which reads less.
  let path = (params["command"] as? String)?.split(separator: ">").map { normalized(String($0)) }
  let read = try menuCommands(app: app, topMenu: (path?.count ?? 0) > 1 ? path?.first : nil)
  // A path or shortcut that looks unique in part of the menus may not be; the command runs only from all of them.
  guard !read.truncated else {
    throw HelperError(code: "timeout", message: "\(app.name)'s menus could not be read in full in time, so the command did not run. Give the whole path from its menu, such as File > Export…, so only that menu is read, or use press with an element number from get_window_state with menu_bar.")
  }
  let all = read.commands
  let command = try resolveCommand(all, params: params)
  try requireAllowedMenu(command.element, app: app)
  guard boolAttribute(command.element, kAXEnabledAttribute) else {
    throw HelperError(code: "disabled", message: "\(command.joinedPath) is disabled now." + (appIsActive(app) ? "" : " " + keyWindowNote))
  }
  let before = checked(command.element)
  let outcome = AXUIElementPerformAction(command.element, kAXPressAction as CFString)
  var result = try pressReply(outcome, "running \(command.joinedPath)", ["path": command.joinedPath, "delivery": "accessibility"])
  // A toggle shows its new state in its checkmark; for other commands the state report below is the evidence.
  sleep(seconds: 0.15)
  if let before, let after = checked(command.element), after != before {
    result["checked"] = after
    if outcome == .success { result["verified"] = true }
  }
  return result
}
