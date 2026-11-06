// Reading a window and acting on it: presses, values, keys, scrolls, clicks and drags, each followed by a report
// of what changed.

import AppKit
import ApplicationServices
import HelperLink

private let pressActions = ["AXPress", "AXConfirm", "AXPick", "AXOpen"]
private let singleLineRoles: Set<String> = [kAXTextFieldRole, kAXComboBoxRole, "AXSearchField"]
private let secureSubrole = "AXSecureTextField"
private let valueWatchChecks = 10
private let valueWatchInterval = 0.05

func applicationElement(_ app: AppIdentity) throws -> AXUIElement {
  try requireAccessibility()
  let element = AXUIElementCreateApplication(app.pid)
  prepareAccessibility(of: element, pid: app.pid)
  return element
}

func selectWindow(_ application: AXUIElement, params: JSON) throws -> AXUIElement {
  let all = windows(of: application)
  guard !all.isEmpty else {
    throw HelperError(code: "window_not_found", message: "The app has no window this helper can reach.")
  }
  guard let index = params["window"] as? Int else { return all[0] }
  guard all.indices.contains(index) else {
    throw HelperError(code: "window_not_found", message: "Window \(index) does not exist; the app has \(all.count).")
  }
  return all[index]
}

private func header(app: AppIdentity, application: AXUIElement, selected: AXUIElement?) -> String {
  var parts = ["app=\"\(app.name)\""]
  // While the screen is locked only the window server knows the windows; they are numbered as screenshot takes them.
  if isScreenLocked() {
    let titles = lockedWindows(pid: app.pid).enumerated().map { "\($0.offset):\"\(clamped($0.element.title))\"" }
    return (parts + ["windows=[\(titles.joined(separator: " "))]", "screen=locked"]).joined(separator: " ")
  }
  let all = windows(of: application)
  let titles = all.enumerated().map { index, window -> String in
    let isSelected = selected.map { CFEqual($0, window) } ?? false
    return "\(index)\(isSelected ? "*" : ""):\"\(clamped(stringAttribute(window, kAXTitleAttribute) ?? ""))\""
  }
  parts.append("windows=[\(titles.joined(separator: " "))]")
  if let selected, hasModal(selected) { parts.append("modal=sheet") }
  return parts.joined(separator: " ")
}

struct WindowRead {
  let header: String
  let tree: RenderedTree
  // The element the read started from, which tells whether a later read is of the same place.
  let root: AXUIElement?
}

func readTree(app: AppIdentity, params: JSON, session: ApprovalSession, shownToAgent: Bool,
              seconds: TimeInterval = treeDeadlineSeconds) throws -> WindowRead {
  let application = try applicationElement(app)
  let maxElements = min(max(params["max_elements"] as? Int ?? defaultMaxElements, 1), 5000)
  var roots: [AXUIElement]
  var selected: AXUIElement?
  if let number = params["root"] as? Int {
    roots = [try session.table.element(number, pid: app.pid)]
  } else if params["menu_bar"] as? Bool == true, let menu = attribute(application, kAXMenuBarAttribute) {
    roots = [menu as! AXUIElement]
  } else if params["menu_extras"] as? Bool == true {
    // The app's own items on the right of the menu bar, such as status icons.
    guard let extras = attribute(application, "AXExtrasMenuBar") else {
      throw HelperError(code: "window_not_found", message: "\(app.name) has no items in the menu bar. System items such as Wi-Fi and Sound belong to Control Center.")
    }
    roots = [extras as! AXUIElement]
  } else {
    selected = try selectWindow(application, params: params)
    roots = [selected!] + openMenus(of: application)
  }
  return WindowRead(header: header(app: app, application: application, selected: selected),
                    tree: renderTree(roots: roots, pid: app.pid, table: session.table, maxElements: maxElements,
                                     shownToAgent: shownToAgent, seconds: seconds),
                    root: roots.first)
}

// An app can bring itself forward in response to an action, for example when it shows or closes a dialog.
// The user was working in another app, so that app gets the focus back. Returns whether it had to.
func returnFocus(to previous: NSRunningApplication?, from pid: pid_t) -> Bool {
  guard let previous, previous.processIdentifier != pid, !previous.isTerminated else { return false }
  return onMain {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
    return previous.activate()
  }
}

// The requests that act on an app, alone or as steps of run_actions.
let actionMethods = Set(actionToolNames)

// Runs one action without reporting its effect, which the caller does once for one action or a sequence.
func performAction(_ method: String, app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  if let number = params["element"] as? Int {
    try requireAllowedMenu(try session.table.element(number, pid: app.pid), app: app)
  }
  switch method {
  case "press": return try press(app: app, params: params, session: session)
  case "set_value": return try setValue(app: app, params: params, session: session)
  case "type_text": return try typeText(app: app, params: params, session: session)
  case "select_text": return try selectText(app: app, params: params, session: session)
  case "press_key":
    let key = try string(params, "key")
    prepareInput(app: app, window: nil)
    try postKey(key, pid: app.pid)
    return ["delivery": "key_events", "verified": false]
  case "scroll": return try scroll(app: app, params: params, session: session)
  case "drag": return try drag(app: app, params: params, session: session)
  case "click_at": return try clickAt(app: app, params: params, session: session)
  default: throw HelperError(code: "unknown_method", message: "Unknown action \(method).")
  }
}

func press(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  let element = try session.table.element(integer(params, "element"), pid: app.pid)
  let available = actions(of: element)
  if let name = params["action"] as? String {
    // Standard actions may be named without their AX prefix; an app's own actions are matched as given.
    let action = available.contains(name) || name.hasPrefix("AX") ? name : "AX\(name)"
    guard available.contains(action) else {
      throw HelperError(code: "action_failed", message: "The element does not offer \(name). It offers: \(available.joined(separator: ", ")).")
    }
    let outcome = AXUIElementPerformAction(element, action as CFString)
    guard outcome == .success else { throw axFailure(outcome, "performing \(name)") }
    return ["delivery": "accessibility", "action": action]
  }
  if let action = pressActions.first(where: available.contains) {
    let outcome = AXUIElementPerformAction(element, action as CFString)
    guard outcome == .success else { throw axFailure(outcome, "pressing the element") }
    return ["delivery": "accessibility", "action": action]
  }
  if isSettable(element, kAXSelectedAttribute) {
    let outcome = AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
    guard outcome == .success else { throw axFailure(outcome, "selecting the element") }
    return ["delivery": "accessibility", "action": "select"]
  }
  guard let box = frame(of: element) else {
    throw HelperError(code: "action_failed", message: "The element has no action and no position.")
  }
  prepareInput(app: app, window: attribute(element, kAXWindowAttribute).map { $0 as! AXUIElement })
  try postClick(at: CGPoint(x: box.midX, y: box.midY), target: pointerTarget(for: element), pid: app.pid, count: 1)
  return ["delivery": "pointer_event", "verified": false]
}

func setValue(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  let element = try session.table.element(integer(params, "element"), pid: app.pid)
  let text = try string(params, "value")
  guard isSettable(element, kAXValueAttribute) else {
    throw HelperError(code: "not_settable", message: "This element's value cannot be set. Try type_text.")
  }
  let before = attribute(element, kAXValueAttribute)
  let value: CFTypeRef
  if before is NSNumber {
    guard let parsed = Double(text), parsed.isFinite else {
      throw HelperError(code: "invalid_request", message: "This element takes a number, not \(text).")
    }
    value = NSNumber(value: parsed)
  } else {
    value = text as NSString
  }
  let outcome = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value)
  guard outcome == .success else { throw axFailure(outcome, "setting the value") }
  // A secure field cannot be read back.
  if stringAttribute(element, kAXSubroleAttribute) == secureSubrole { return ["delivery": "accessibility", "verified": false] }
  if sameValue(before, value) { return ["delivery": "accessibility", "verified": true] }
  switch watchValue(of: element, from: before, until: value) {
  case .reached:
    return ["delivery": "accessibility", "verified": true]
  case .unchanged:
    throw HelperError(code: "outcome_unknown", message: "The app accepted the value, but the element still shows the old one. Read the state before trying again.")
  case .unreadable:
    return ["delivery": "accessibility", "verified": false]
  case .changed:
    // The app stored something else, for example by limiting a number.
    return ["delivery": "accessibility", "verified": false, "value": describeValue(attribute(element, kAXValueAttribute)) ?? ""]
  }
}

private func sameValue(_ first: AnyObject?, _ second: AnyObject?) -> Bool {
  guard let first, let second else { return first == nil && second == nil }
  return CFEqual(first, second)
}

private enum ValueWatch {
  case reached, changed, unchanged, unreadable
}

// Apps may apply a change a moment after accepting it. Stops early once the value differs from `before`,
// or, when a target is given, once it matches the target.
private func watchValue(of element: AXUIElement, from before: AnyObject?, until target: AnyObject? = nil) -> ValueWatch {
  var outcome = ValueWatch.unchanged
  for _ in 0..<valueWatchChecks {
    let current = attribute(element, kAXValueAttribute)
    if current == nil, before != nil {
      outcome = .unreadable
    } else if let target, sameValue(current, target) {
      return .reached
    } else if !sameValue(current, before) {
      if target == nil { return .changed }
      outcome = .changed
    } else {
      outcome = .unchanged
    }
    sleep(seconds: valueWatchInterval)
  }
  return outcome
}

func requireTextForKeys(_ text: String) throws {
  // Return may submit a form and Tab moves the focus, so these never go out as a side effect of text.
  if text.contains(where: { $0.isNewline || $0 == "\t" }) {
    throw HelperError(code: "invalid_request", message: "This route sends keys, so line breaks and tabs are refused. Use press_key for them.")
  }
}

// Once text may have arrived, no later route runs, so nothing is inserted twice.
func typeText(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  let text = try nonEmptyString(params, "text")
  guard let number = params["element"] as? Int else {
    try requireTextForKeys(text)
    prepareInput(app: app, window: nil)
    try postText(text, pid: app.pid)
    return ["delivery": "key_events", "verified": false]
  }
  let element = try session.table.element(number, pid: app.pid)
  let isSecure = stringAttribute(element, kAXSubroleAttribute) == secureSubrole
  let isSingleLine = isSecure || singleLineRoles.contains(stringAttribute(element, kAXRoleAttribute) ?? "")
  if isSingleLine, text.contains(where: \.isNewline) {
    throw HelperError(code: "invalid_request", message: "This field holds one line. Use press_key with return to submit it.")
  }

  let before = isSecure ? nil : textAttribute(element, kAXValueAttribute)
  if let before {
    if isSettable(element, kAXSelectedTextAttribute) {
      let selectedBefore = textAttribute(element, kAXSelectedTextAttribute)
      let outcome = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as NSString)
      if outcome == .cannotComplete { throw axFailure(outcome, "inserting the text") }
      if outcome == .success {
        // Replacing a selection with the same text leaves the value as it was.
        if selectedBefore == text { return ["delivery": "accessibility", "verified": false] }
        switch watchValue(of: element, from: before as NSString) {
        case .changed, .reached:
          return ["delivery": "accessibility", "verified": true]
        case .unreadable:
          return ["delivery": "accessibility", "verified": false]
        case .unchanged:
          // Only an unfocused one-line field is known to answer success and change nothing.
          if !isSingleLine || boolAttribute(element, kAXFocusedAttribute) {
            throw HelperError(code: "outcome_unknown", message: "The app accepted the text, but the element still shows the old value. Read the state before trying again.")
          }
        }
      }
    }
    // Only plain one-line fields, because writing a document's value would lose its formatting, and only
    // unfocused ones, because a focused field has a cursor that keys can respect.
    if isSingleLine, !boolAttribute(element, kAXFocusedAttribute), isSettable(element, kAXValueAttribute) {
      let appended = before + text
      let outcome = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, appended as NSString)
      if outcome == .cannotComplete { throw axFailure(outcome, "inserting the text") }
      if outcome == .success {
        switch watchValue(of: element, from: before as NSString, until: appended as NSString) {
        case .reached:
          return ["delivery": "value_appended_at_end", "verified": true]
        case .changed, .unreadable:
          return ["delivery": "value_appended_at_end", "verified": false]
        case .unchanged:
          throw HelperError(code: "outcome_unknown", message: "The app accepted the text, but the field still shows the old value. Read the state before trying again.")
        }
      }
    }
  }

  // Keys go wherever the app's focus is, so they are sent only once it is on this element.
  try requireTextForKeys(text)
  prepareInput(app: app, window: attribute(element, kAXWindowAttribute).map { $0 as! AXUIElement })
  AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
  sleep(seconds: 0.05)
  let focused = attribute(AXUIElementCreateApplication(app.pid), kAXFocusedUIElementAttribute)
  guard let focused, CFEqual(focused, element) else {
    throw HelperError(code: "action_failed", message: "Could not focus this element, so nothing was typed.")
  }
  try postText(text, pid: app.pid)
  guard let before else { return ["delivery": "key_events", "verified": false] }
  if case .changed = watchValue(of: element, from: before as NSString) { return ["delivery": "key_events", "verified": true] }
  return ["delivery": "key_events", "verified": false]
}

func scroll(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  let direction = try string(params, "direction")
  let pages = min(max(params["pages"] as? Int ?? 1, 1), 20)
  guard ["up", "down", "left", "right"].contains(direction) else {
    throw HelperError(code: "invalid_request", message: "direction must be up, down, left or right.")
  }
  let element = try session.table.element(integer(params, "element"), pid: app.pid)
  let vertical = direction == "up" || direction == "down"
  let forward = direction == "down" || direction == "right"

  var current: AXUIElement? = element
  var hops = 0
  while let candidate = current, hops < 12 {
    let barName = vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute
    if let barValue = attribute(candidate, barName) {
      let bar = barValue as! AXUIElement
      if let position = attribute(bar, kAXValueAttribute) as? Double, isSettable(bar, kAXValueAttribute) {
        let next = min(max(position + (forward ? 0.25 : -0.25) * Double(pages), 0), 1)
        let outcome = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: next))
        guard outcome == .success else { throw axFailure(outcome, "scrolling") }
        return ["delivery": "accessibility"]
      }
    }
    current = attribute(candidate, kAXParentAttribute).map { $0 as! AXUIElement }
    hops += 1
  }
  guard vertical, let box = frame(of: element) else {
    throw HelperError(code: "action_failed", message: "No scroll bar was found for this element.")
  }
  try postScroll(at: CGPoint(x: box.midX, y: box.midY), target: pointerTarget(for: element), pid: app.pid, lines: Int32((forward ? -10 : 10) * pages))
  return ["delivery": "pointer_event", "verified": false]
}

// Chromium ignores input to a window that is not key, so its window is made key inside the app first. An app
// the user is working in already has its key window.
func prepareInput(app: AppIdentity, window: AXUIElement?) {
  guard isChromiumApp(path: app.path),
        onMain({ NSRunningApplication(processIdentifier: app.pid)?.isActive }) == false else { return }
  let application = AXUIElementCreateApplication(app.pid)
  let target = window ?? attribute(application, kAXMainWindowAttribute).map { $0 as! AXUIElement } ?? windows(of: application).first
  guard let target, let number = windowNumber(of: target) else { return }
  _ = makeKeyInApp(window: number, pid: app.pid)
}

// A click at a point in window coordinates, or at an element's center.
func clickAt(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  let application = try applicationElement(app)
  let style = try ClickStyle.parse(button: params["button"] as? String, modifiers: params["modifiers"] as? [String] ?? [])
  let window: AXUIElement
  let point: CGPoint
  if let number = params["element"] as? Int {
    let element = try session.table.element(number, pid: app.pid)
    guard let box = frame(of: element) else { throw HelperError(code: "action_failed", message: "The element has no position.") }
    window = try attribute(element, kAXWindowAttribute).map { $0 as! AXUIElement } ?? selectWindow(application, params: params)
    point = CGPoint(x: box.midX, y: box.midY)
  } else {
    guard params["x"] != nil, params["y"] != nil else {
      throw HelperError(code: "invalid_request", message: "Give element, or x and y.")
    }
    let x = try number(params, "x")
    let y = try number(params, "y")
    window = try selectWindow(application, params: params)
    guard let box = frame(of: window) else {
      throw HelperError(code: "action_failed", message: "The window has no position.")
    }
    guard x >= 0, y >= 0, x <= box.width, y <= box.height else {
      throw HelperError(code: "out_of_window", message: "The point is outside the window (\(Int(box.width))×\(Int(box.height))).")
    }
    point = CGPoint(x: box.minX + x, y: box.minY + y)
  }
  let count = params["count"] as? Int ?? 1
  if params["foreground"] as? Bool == true {
    try postForegroundClick(at: point, window: window, pid: app.pid, count: count, style: style)
    return ["delivery": "foreground_pointer_event", "verified": false, "window": stringAttribute(window, kAXTitleAttribute) ?? ""]
  }
  prepareInput(app: app, window: window)
  try postClick(at: point, target: pointerTarget(for: window), pid: app.pid, count: count, style: style)
  return ["delivery": "pointer_event", "verified": false, "window": stringAttribute(window, kAXTitleAttribute) ?? ""]
}

// Each end is an element's center or a point in window coordinates; the window is the element's, or the one chosen.
private func dragPoint(_ end: String, app: AppIdentity, params: JSON, session: ApprovalSession, window: AXUIElement) throws -> (point: CGPoint, window: AXUIElement) {
  if let number = params["\(end)_element"] as? Int {
    let element = try session.table.element(number, pid: app.pid)
    guard let box = frame(of: element) else { throw HelperError(code: "action_failed", message: "The \(end) element has no position.") }
    let owner = attribute(element, kAXWindowAttribute).map { $0 as! AXUIElement } ?? window
    return (CGPoint(x: box.midX, y: box.midY), owner)
  }
  guard let x = params["\(end)_x"] as? Double, let y = params["\(end)_y"] as? Double else {
    throw HelperError(code: "invalid_request", message: "Give \(end)_element, or \(end)_x and \(end)_y.")
  }
  guard let box = frame(of: window), x >= 0, y >= 0, x <= box.width, y <= box.height else {
    throw HelperError(code: "out_of_window", message: "The \(end) point is outside the window.")
  }
  return (CGPoint(x: box.minX + x, y: box.minY + y), window)
}

func drag(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  let window = try selectWindow(try applicationElement(app), params: params)
  let start = try dragPoint("from", app: app, params: params, session: session, window: window)
  let end = try dragPoint("to", app: app, params: params, session: session, window: window)
  guard CFEqual(start.window, end.window) else {
    throw HelperError(code: "invalid_request", message: "Both ends must be in the same window.")
  }
  prepareInput(app: app, window: start.window)
  try postDrag(from: start.point, to: end.point, target: pointerTarget(for: start.window), pid: app.pid)
  return ["delivery": "pointer_event", "verified": false]
}
