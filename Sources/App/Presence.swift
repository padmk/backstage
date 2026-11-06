// The user working in the app an agent is about to act in, where the agent's input would mix with theirs, and a
// locked screen, where windows cannot be read or operated.

import AppKit

// Input this recent in the front app counts as the user working there.
private let userActiveSeconds = 2.0

func requireUserNotWorking(in app: AppIdentity) throws {
  guard onMain({ NSWorkspace.shared.frontmostApplication?.processIdentifier }) == app.pid else { return }
  let anyInput = CGEventType(rawValue: ~0)!
  let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
  guard idle >= userActiveSeconds else {
    throw HelperError(code: "user_active", message: "The user is working in \(app.name) right now, so nothing was done there. Try again in a few seconds, or ask the user.")
  }
}

// While the screen is locked, macOS keeps the windows out of the accessibility tree (the app stands in for each of
// them) and out of ScreenCaptureKit, so window requests stop here with a clear reason. The app's menu bar stays
// readable and its items still work, so reading the menu bar and pressing its items go on. Ready operations go
// through scripting and EventKit, not windows, and are not stopped.
func isScreenLocked() -> Bool {
  let session = CGSessionCopyCurrentDictionary() as? [String: Any]
  return session?["CGSSessionScreenIsLocked"] as? Bool == true
}

func requireScreenUnlocked(_ method: String, params: JSON, app: AppIdentity, session: ApprovalSession) throws {
  guard isScreenLocked(), !worksWhileLocked(method, params: params, app: app, session: session),
    !worksOnLockedWindows(method, params: params) else { return }
  let windows = Preferences.worksInWindowsWhileLocked
    ? " The user also allows screenshot, click_at with x and y, and press_key and type_text without an element; they work from screenshots and are never verified."
    : ""
  throw HelperError(
    code: "screen_locked",
    message: "The Mac's screen is locked, so app windows cannot be read until the user unlocks it. Still available: ready operations (list_operations), and the app's menu bar: get_window_state with menu_bar: true, then press on its menu items.\(windows) Do not try to unlock it; wait or tell the user.")
}

private let menuRoles: Set<String> = ["AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem"]

private func worksWhileLocked(_ method: String, params: JSON, app: AppIdentity, session: ApprovalSession) -> Bool {
  func isMenu(_ number: Any?) -> Bool {
    guard let number = number as? Int, let element = try? session.table.element(number, pid: app.pid) else { return false }
    return stringAttribute(element, kAXRoleAttribute).map(menuRoles.contains) ?? false
  }
  switch method {
  case "get_window_state":
    if let root = params["root"] { return isMenu(root) }
    return params["menu_bar"] as? Bool == true || params["menu_extras"] as? Bool == true
  case "press":
    return isMenu(params["element"])
  // Hiding and showing go through the app, and menus stay readable and usable while locked.
  case "set_app_state", "list_menu_commands", "run_menu_command":
    return true
  case "run_actions":
    guard let steps = params["steps"] as? [JSON], !steps.isEmpty else { return false }
    return steps.allSatisfy { $0["tool"] as? String == "press" && isMenu($0["element"]) }
  default:
    return false
  }
}
