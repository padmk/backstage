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
  let shortcut: String?

  var joinedPath: String { path.joined(separator: " > ") }
}

private func shortcut(of item: AXUIElement) -> String? {
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
// stale enabled state. The Apple menu and the Services and Share menus are left out; they are never available.
func menuCommands(app: AppIdentity, limit: Int = .max) throws -> (commands: [MenuCommand], truncated: Bool) {
  let application = try applicationElement(app)
  guard let bar = attribute(application, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) else {
    throw HelperError(code: "window_not_found", message: "\(app.name) has no menu bar.")
  }
  var found: [MenuCommand] = []
  var truncated = false
  let started = Date()
  func walk(_ menuParent: AXUIElement, path: [String], depth: Int) {
    guard depth < maxDepth else {
      truncated = true
      return
    }
    for menu in (attribute(menuParent, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
      for item in (attribute(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        guard found.count < limit, Date().timeIntervalSince(started) < listSeconds else {
          truncated = true
          return
        }
        let title = stringAttribute(item, kAXTitleAttribute) ?? ""
        guard !title.isEmpty else { continue }
        if restrictedMenu(item, in: application) != nil { continue }
        let itemPath = path + [title]
        let children = (attribute(item, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        if children.isEmpty {
          found.append(MenuCommand(path: itemPath, element: item, shortcut: shortcut(of: item)))
        } else {
          walk(item, path: itemPath, depth: depth + 1)
        }
      }
    }
  }
  let tops = (attribute(bar, kAXChildrenAttribute) as? [AXUIElement]) ?? []
  for top in tops.dropFirst() {
    guard !truncated else { break }
    walk(top, path: [stringAttribute(top, kAXTitleAttribute) ?? ""], depth: 1)
  }
  return (found, truncated)
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
  let (all, truncated) = try menuCommands(app: app)
  var listed: [JSON] = []
  var more = truncated
  for command in all {
    let enabled = boolAttribute(command.element, kAXEnabledAttribute)
    if enabledOnly, !enabled { continue }
    if let query, !command.joinedPath.lowercased().contains(query), command.shortcut?.contains(query) != true { continue }
    guard listed.count < max else {
      more = true
      break
    }
    var entry: JSON = ["path": command.joinedPath, "enabled": enabled,
                       "element": session.table.number(for: command.element, pid: app.pid, shownToAgent: true)]
    if let shortcut = command.shortcut { entry["shortcut"] = shortcut }
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
    let wanted = Set(key.lowercased().split(separator: "+").map(String.init))
    matches = all.filter { command in command.shortcut.map { Set($0.split(separator: "+").map(String.init)) == wanted } ?? false }
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
  let (all, truncated) = try menuCommands(app: app)
  // A path or shortcut that looks unique in part of the menus may not be; the command runs only from all of them.
  guard !truncated else {
    throw HelperError(code: "outcome_unknown", message: "\(app.name)'s menus could not be read in full in time, so the command did not run. Try again, or use press with an element number from list_menu_commands.")
  }
  let command = try resolveCommand(all, params: params)
  try requireAllowedMenu(command.element, app: app)
  guard boolAttribute(command.element, kAXEnabledAttribute) else {
    throw HelperError(code: "disabled", message: "\(command.joinedPath) is disabled now." + (appIsActive(app) ? "" : " " + keyWindowNote))
  }
  let before = checked(command.element)
  let outcome = AXUIElementPerformAction(command.element, kAXPressAction as CFString)
  guard outcome == .success else { throw axFailure(outcome, "running \(command.joinedPath)") }
  var result: JSON = ["path": command.joinedPath, "delivery": "accessibility"]
  // A toggle shows its new state in its checkmark; for other commands the state report below is the evidence.
  sleep(seconds: 0.15)
  if let before, let after = checked(command.element), after != before {
    result["checked"] = after
    result["verified"] = true
  }
  return result
}
