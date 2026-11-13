// The user working in the app an agent is about to act in, where the agent's input would mix with theirs, and a
// locked screen, where windows cannot be read or operated.

import AppKit

// Input this recent counts as the user working in the app.
private let userActiveSeconds = 2.0
// Typing and clicking go to the front app wherever the pointer is.
private let directedInput: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
// Moving the pointer and scrolling reach the window under the pointer, which may belong to another app, as when the
// user reads in another window while this app stays in front.
private let pointerInput: [CGEventType] = [.mouseMoved, .scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
// A window in the background takes scrolling, dragging and some clicks without its app coming forward. Only moving
// the pointer across it on the way elsewhere is not counted.
private let backgroundInput: [CGEventType] = [.scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
  .leftMouseDown, .rightMouseDown, .otherMouseDown]

// When Backstage last posted input to the whole system (a click with foreground) or put the pointer back, which the
// system's input times count as the user's own. Input to an app's process does not reach them.
// The system may stamp posted input a moment after the post returns.
private let ownInputMarginSeconds = 0.1
private let ownInputLock = NSLock()
private var ownSystemInputAt = Date.distantPast

func noteOwnSystemInput() {
  ownInputLock.lock()
  ownSystemInputAt = Date()
  ownInputLock.unlock()
}

private func secondsSinceOwnSystemInput() -> Double {
  ownInputLock.lock()
  defer { ownInputLock.unlock() }
  return Date().timeIntervalSince(ownSystemInputAt)
}

// How long ago the user last gave input of these types, ignoring input no newer than Backstage's own. The HID state
// does not keep a time for scrolling, so that comes from the session state, which input posted to a process does not
// reach either.
private func secondsSinceUserInput(_ types: [CGEventType]) -> Double {
  let latest = types.map { type in
    CGEventSource.secondsSinceLastEventType(type == .scrollWheel ? .combinedSessionState : .hidSystemState, eventType: type)
  }.min() ?? .infinity
  return latest < secondsSinceOwnSystemInput() - ownInputMarginSeconds ? latest : .infinity
}

// The visible window under the pointer, top first, belongs to the app.
private func pointerIsOverWindow(of pid: pid_t) -> Bool {
  guard let location = CGEvent(source: nil)?.location,
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [JSON]
  else { return false }
  let top = windows.first { window in
    guard (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
      let bounds = window[kCGWindowBounds as String] as? NSDictionary,
      let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
    return frame.contains(location)
  }
  return (top?[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) == pid } ?? false
}

// In the front app the user's typing and clicking count wherever the pointer is; in any app, pointer input over its
// window on top.
func requireUserNotWorking(in app: AppIdentity) throws {
  let isFront = onMain({ NSWorkspace.shared.frontmostApplication?.processIdentifier }) == app.pid
  let working = (isFront && secondsSinceUserInput(directedInput) < userActiveSeconds)
    || (secondsSinceUserInput(isFront ? pointerInput : backgroundInput) < userActiveSeconds && pointerIsOverWindow(of: app.pid))
  guard !working else {
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
  // Sound needs no window; only a press on a window's element does.
  case "record_audio":
    return params["press"] == nil || isMenu(params["press"])
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
