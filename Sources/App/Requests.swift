// Every request that touches an app resolves it, passes the gate, and proves the process is still the
// one approved, because a pid can be reused while the user reads the window.

import AppKit
import HelperLink
import ApplicationServices

private let settleSeconds = 1.0
private let launchTimeoutSeconds = 20
// How long a starting app is watched for taking the focus, and how long it must leave it alone once started.
private let launchFocusWatchSeconds = 8.0
private let launchQuietSeconds = 1.5
private let pressActions = ["AXPress", "AXConfirm", "AXPick", "AXOpen"]
private let maxRememberedReads = 32
private let singleLineRoles: Set<String> = [kAXTextFieldRole, kAXComboBoxRole, "AXSearchField"]
private let secureSubrole = "AXSecureTextField"
private let valueWatchChecks = 10
private let valueWatchInterval = 0.05

func onMain<T>(_ work: () -> T) -> T {
  Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
}

func describe(_ app: NSRunningApplication) -> JSON {
  [
    "pid": Int(app.processIdentifier), "name": app.localizedName ?? "", "bundle_id": app.bundleIdentifier ?? "",
    "active": app.isActive, "hidden": app.isHidden,
  ]
}

private func visibleApps() -> [NSRunningApplication] {
  onMain { NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular } }
}

private func identity(of app: NSRunningApplication) -> AppIdentity {
  AppIdentity(
    pid: app.processIdentifier, bundleId: app.bundleIdentifier ?? "", name: app.localizedName ?? app.bundleIdentifier ?? "app",
    launchDate: app.launchDate, path: app.bundleURL?.path)
}

// Apps with a Dock icon first. An app without one, such as Control Center, is reachable only when it has items
// in the menu bar, which are often its only interface; system processes such as the Dock stay out of reach.
private func resolve(_ query: String) throws -> AppIdentity {
  let lowered = query.lowercased()
  let find = { (apps: [NSRunningApplication]) in
    apps.first { $0.bundleIdentifier?.lowercased() == lowered }
      ?? apps.first { $0.localizedName?.lowercased() == lowered }
      ?? Int(query).flatMap { pid in apps.first { Int($0.processIdentifier) == pid } }
  }
  let match = find(visibleApps()) ?? find(onMain { NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .accessory } })
    .flatMap { app in hasMenuExtras(pid: app.processIdentifier) ? app : nil }
  guard let match else {
    throw HelperError(code: "app_not_found", message: "\(query) is not running. Use launch_app first.")
  }
  return identity(of: match)
}

private func hasMenuExtras(pid: pid_t) -> Bool {
  AXIsProcessTrusted() && attribute(AXUIElementCreateApplication(pid), "AXExtrasMenuBar") != nil
}

private func requireSameProcess(_ app: AppIdentity) throws {
  let current = onMain { NSRunningApplication(processIdentifier: app.pid) }
  guard let current, !current.isTerminated, current.bundleIdentifier == app.bundleId, current.launchDate == app.launchDate else {
    throw HelperError(code: "app_changed", message: "\(app.name) stopped while waiting. Try again.")
  }
}

// Only names, never paths, so a request cannot point the helper at a bundle of its choosing.
private func installedApp(_ query: String) throws -> URL {
  guard !query.contains("/"), !query.contains("\0") else {
    throw HelperError(code: "invalid_request", message: "Give an app name or bundle id, not a path.")
  }
  let url: URL? = onMain {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: query)
      ?? ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"].lazy
        .map { URL(fileURLWithPath: "\($0)/\(query).app") }
        .first { FileManager.default.fileExists(atPath: $0.path) }
  }
  guard let url else { throw HelperError(code: "app_not_found", message: "\(query) is not installed.") }
  return url
}

private func installedIdentity(_ url: URL) throws -> AppIdentity {
  guard let bundleId = Bundle(url: url)?.bundleIdentifier else {
    throw HelperError(code: "app_not_found", message: "\(url.lastPathComponent) has no bundle identifier.")
  }
  return AppIdentity(pid: 0, bundleId: bundleId, name: url.deletingPathExtension().lastPathComponent, launchDate: nil, path: url.path)
}

private func launch(_ query: String, session: ApprovalSession, connection: Connection) throws -> JSON {
  let url = try installedApp(query)
  guard let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier else {
    throw HelperError(code: "app_not_found", message: "\(query) has no bundle identifier.")
  }
  let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
  try ApprovalGate.require(
    AppIdentity(pid: 0, bundleId: bundleId, name: name, launchDate: nil, path: url.path), session: session)

  // Opening a running app sends it a reopen event, which can show a window and take the focus, so it is left as it is.
  if let running = onMain({ NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first { !$0.isTerminated } }) {
    var result = describe(running)
    result["already_running"] = true
    return result
  }
  let frontBefore = onMain { NSWorkspace.shared.frontmostApplication }
  let configuration = NSWorkspace.OpenConfiguration()
  configuration.activates = false
  configuration.addsToRecentItems = false
  let done = DispatchSemaphore(value: 0)
  var launched: NSRunningApplication?
  var failure: Error?
  NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
    launched = app
    failure = error
    done.signal()
  }
  // The app can take the focus before the launch is reported, so it is watched while waiting too.
  let launchDeadline = Date().addingTimeInterval(TimeInterval(launchTimeoutSeconds))
  var returnedEarly = false
  while done.wait(timeout: .now() + 0.05) == .timedOut {
    if let frontBefore, frontBefore.bundleIdentifier != bundleId,
       onMain({ NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) == bundleId {
      returnedEarly = onMain { frontBefore.activate() } || returnedEarly
    }
    guard Date() < launchDeadline else { throw HelperError(code: "timeout", message: "\(name) did not start in time.") }
  }
  if let failure { throw HelperError(code: "action_failed", message: failure.localizedDescription) }
  guard let launched else { throw HelperError(code: "action_failed", message: "\(name) did not start.") }
  let focusReturned = keepFocusWhileStarting(launched, previous: frontBefore) || returnedEarly
  var result = describe(launched)
  if focusReturned { result["focus_returned"] = true }
  return result
}

// Many apps activate themselves as they start, despite the request not to. While it starts, the app the user
// was in gets the focus back each time, which also leaves the new app's windows behind it. Returns whether it had to.
private func keepFocusWhileStarting(_ launched: NSRunningApplication, previous: NSRunningApplication?) -> Bool {
  guard let previous, previous.processIdentifier != launched.processIdentifier else { return false }
  let deadline = Date().addingTimeInterval(launchFocusWatchSeconds)
  var quietSince = Date()
  var returned = false
  while Date() < deadline, !launched.isTerminated {
    if onMain({ NSWorkspace.shared.frontmostApplication?.processIdentifier }) == launched.processIdentifier {
      returned = onMain { previous.activate() } || returned
      quietSince = Date()
    } else if launched.isFinishedLaunching, Date().timeIntervalSince(quietSince) >= launchQuietSeconds {
      break
    }
    sleep(seconds: 0.05)
  }
  return returned
}

private func applicationElement(_ app: AppIdentity) throws -> AXUIElement {
  try requireAccessibility()
  let element = AXUIElementCreateApplication(app.pid)
  prepareAccessibility(of: element, pid: app.pid)
  return element
}

private func selectWindow(_ application: AXUIElement, params: JSON) throws -> AXUIElement {
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
  let all = windows(of: application)
  var parts = ["app=\"\(app.name)\""]
  let titles = all.enumerated().map { index, window -> String in
    let isSelected = selected.map { CFEqual($0, window) } ?? false
    return "\(index)\(isSelected ? "*" : ""):\"\(clamped(stringAttribute(window, kAXTitleAttribute) ?? ""))\""
  }
  parts.append("windows=[\(titles.joined(separator: " "))]")
  if let selected, hasModal(selected) { parts.append("modal=sheet") }
  return parts.joined(separator: " ")
}

private func readTree(app: AppIdentity, params: JSON, session: ApprovalSession, shownToAgent: Bool) throws -> (header: String, tree: RenderedTree) {
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
  return (header(app: app, application: application, selected: selected),
          renderTree(roots: roots, pid: app.pid, table: session.table, maxElements: maxElements, shownToAgent: shownToAgent))
}

// Runs an action, then reports what changed in the app's last read, so the agent sees the effect and no
// action claims a success it did not observe.
private func acting(app: AppIdentity, session: ApprovalSession, _ action: () throws -> JSON) throws -> JSON {
  let frontBefore = onMain { NSWorkspace.shared.frontmostApplication }
  var result: JSON
  do {
    result = try action()
  } catch {
    _ = returnFocus(to: frontBefore, from: app.pid)
    throw error
  }
  defer { _ = returnFocus(to: frontBefore, from: app.pid) }
  if returnFocus(to: frontBefore, from: app.pid) { result["focus_returned"] = true }
  guard let last = session.lock.withLock({ session.lastReads[app.pid] }) else {
    result["state"] = ["unknown": true, "reason": "Nothing was read before this action, so changes cannot be reported."] as JSON
    return result
  }
  if last.isPartial {
    result["state"] = ["unknown": true, "reason": "The last read was partial, so changes cannot be reported. Read a smaller area with root."] as JSON
    return result
  }
  let deadline = Date().addingTimeInterval(settleSeconds)
  var after = last.lines
  repeat {
    sleep(seconds: 0.1)
    let read: RenderedTree
    do {
      read = try readTree(app: app, params: last.request, session: session, shownToAgent: false).tree
    } catch {
      let reason = (error as? HelperError)?.message ?? error.localizedDescription
      result["state"] = ["unknown": true, "reason": "The earlier read cannot be repeated: \(reason)"] as JSON
      return result
    }
    if let partial = read.partialReason {
      result["state"] = ["unknown": true, "reason": "The app answered only in part: \(partial)"] as JSON
      return result
    }
    after = read.lines
    if after != last.lines { break }
  } while Date() < deadline
  result["state"] = changeReport(before: last.lines, after: after)
  session.lock.withLock { session.lastReads[app.pid] = LastRead(request: last.request, lines: after, isPartial: false) }
  return result
}

// An app can bring itself forward in response to an action, for example when it shows or closes a dialog.
// The user was working in another app, so that app gets the focus back. Returns whether it had to.
private func returnFocus(to previous: NSRunningApplication?, from pid: pid_t) -> Bool {
  guard let previous, previous.processIdentifier != pid, !previous.isTerminated else { return false }
  return onMain {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
    return previous.activate()
  }
}

private func press(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
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

private func setValue(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
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

private func requireTextForKeys(_ text: String) throws {
  // Return may submit a form and Tab moves the focus, so these never go out as a side effect of text.
  if text.contains(where: { $0.isNewline || $0 == "\t" }) {
    throw HelperError(code: "invalid_request", message: "This route sends keys, so line breaks and tabs are refused. Use press_key for them.")
  }
}

// Once text may have arrived, no later route runs, so nothing is inserted twice.
private func typeText(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  let text = try string(params, "text")
  guard !text.isEmpty else { throw HelperError(code: "invalid_request", message: "text is empty.") }
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

private func scroll(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
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
private func prepareInput(app: AppIdentity, window: AXUIElement?) {
  guard isChromiumApp(path: app.path),
        onMain({ NSRunningApplication(processIdentifier: app.pid)?.isActive }) == false else { return }
  let application = AXUIElementCreateApplication(app.pid)
  let target = window ?? attribute(application, kAXMainWindowAttribute).map { $0 as! AXUIElement } ?? windows(of: application).first
  guard let target, let number = windowNumber(of: target) else { return }
  _ = makeKeyInApp(window: number, pid: app.pid)
}

private func clickAt(app: AppIdentity, params: JSON) throws -> JSON {
  let application = try applicationElement(app)
  let x = try number(params, "x")
  let y = try number(params, "y")
  let window = try selectWindow(application, params: params)
  guard let box = frame(of: window) else {
    throw HelperError(code: "action_failed", message: "The window has no position.")
  }
  guard x >= 0, y >= 0, x <= box.width, y <= box.height else {
    throw HelperError(code: "out_of_window", message: "The point is outside the window (\(Int(box.width))×\(Int(box.height))).")
  }
  let point = CGPoint(x: box.minX + x, y: box.minY + y)
  let count = params["count"] as? Int ?? 1
  if params["foreground"] as? Bool == true {
    try postForegroundClick(at: point, window: window, pid: app.pid, count: count)
    return ["delivery": "foreground_pointer_event", "verified": false, "window": stringAttribute(window, kAXTitleAttribute) ?? ""]
  }
  prepareInput(app: app, window: window)
  try postClick(at: point, target: pointerTarget(for: window), pid: app.pid, count: count)
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

private func drag(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
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

func handle(method: String, params: JSON, connection: Connection) throws -> Any {
  let session = connection.session
  switch method {
  case "hello":
    session.lock.withLock {
      session.clientName = params["client_name"] as? String
    }
    return ["version": Configuration.buildVersion, "build": ownBuildIdentity] as JSON

  case "status":
    return [
      "accessibility": AXIsProcessTrusted(), "screen_recording": CGPreflightScreenCaptureAccess(), "version": Configuration.buildVersion,
      // The same grants as the Permissions tab: those of the listed apps.
      "app_access": appGrants(forListed: Set(ApprovalStore.list().compactMap { $0["bundle_id"] }), everyApp: Preferences.allowsEveryApp)
        .map { ["name": $0.name, "state": grantState($0).rawValue] as JSON },
    ] as JSON

  case "request_permissions":
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let accessibility = AXIsProcessTrustedWithOptions(options)
    // Screen Recording is optional, so it is asked for only when the caller says so.
    let screen = CGPreflightScreenCaptureAccess() || (params["screen_recording"] as? Bool == true && CGRequestScreenCaptureAccess())
    return ["accessibility": accessibility, "screen_recording": screen] as JSON

  case "quit":
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      unlink(Configuration.socketPath)
      exit(0)
    }
    return [:] as JSON

  case "approvals_list":
    return ["approvals": ApprovalStore.list()] as JSON

  case "approvals_revoke":
    let bundleId = try string(params, "bundle_id")
    let revoked = try ApprovalStore.revoke(bundleId: bundleId)
    if revoked { writeDecisionLog(client: commandLineClient, bundleId: bundleId, decision: "removed") }
    return ["revoked": revoked] as JSON

  case "approvals_add":
    let query = try string(params, "app")
    let app = try (try? resolve(query)) ?? installedIdentity(try installedApp(query))
    try addToList(app, by: commandLineClient)
    return ["added": app.bundleId, "name": app.name] as JSON

  case "list_apps":
    // With app: that one app, running or only installed, without starting it.
    if let query = params["app"] as? String {
      let app = try (try? resolve(query)) ?? installedIdentity(try installedApp(query))
      return ["app": ["name": app.name, "bundle_id": app.bundleId, "running": app.pid != 0, "access": ApprovalGate.access(app).rawValue],
              "every_app": Preferences.allowsEveryApp] as JSON
    }
    return ["apps": visibleApps().map { running in
      var entry = describe(running)
      entry["access"] = ApprovalGate.access(identity(of: running)).rawValue
      return entry
    }, "every_app": Preferences.allowsEveryApp] as JSON

  case "launch_app":
    return try launch(string(params, "app"), session: session, connection: connection)

  case "list_operations":
    return try listOperations(params)

  case "run_operation":
    return try runOperation(params, session: session, connection: connection)

  default:
    break
  }

  guard ["get_window_state", "screenshot", "press", "set_value", "type_text", "press_key", "scroll", "click_at", "drag"].contains(method) else {
    throw HelperError(code: "unknown_method", message: "Unknown method \(method).")
  }

  let app = try resolve(string(params, "app"))
  try ApprovalGate.require(app, session: session)
  try requireSameProcess(app)
  try connection.throwIfCancelled()

  switch method {
  case "get_window_state":
    let read = try readTree(app: app, params: params, session: session, shownToAgent: true)
    session.lock.withLock {
      if session.lastReads.count >= maxRememberedReads { session.lastReads.removeAll() }
      session.lastReads[app.pid] = LastRead(request: params, lines: read.tree.lines, isPartial: read.tree.partialReason != nil)
    }
    let knowledge = knowledgeLines(forBundleId: app.bundleId)
    var text = ([read.header] + knowledge + read.tree.lines).joined(separator: "\n")
    if let reason = read.tree.partialReason { text += "\n[Partial: \(reason)]" }
    return ["tree": text] as JSON

  case "screenshot":
    let application = try applicationElement(app)
    return try captureWindow(pid: app.pid, window: selectWindow(application, params: params))

  case "press":
    try requireAccessibility()
    return try acting(app: app, session: session) { try press(app: app, params: params, session: session) }

  case "set_value":
    try requireAccessibility()
    return try acting(app: app, session: session) { try setValue(app: app, params: params, session: session) }

  case "type_text":
    try requireAccessibility()
    return try acting(app: app, session: session) { try typeText(app: app, params: params, session: session) }

  case "press_key":
    try requireAccessibility()
    let key = try string(params, "key")
    return try acting(app: app, session: session) {
      prepareInput(app: app, window: nil)
      try postKey(key, pid: app.pid)
      return ["delivery": "key_events", "verified": false]
    }

  case "scroll":
    try requireAccessibility()
    return try acting(app: app, session: session) { try scroll(app: app, params: params, session: session) }

  case "drag":
    try requireAccessibility()
    return try acting(app: app, session: session) { try drag(app: app, params: params, session: session) }

  default:
    try requireAccessibility()
    return try acting(app: app, session: session) { try clickAt(app: app, params: params) }
  }
}
