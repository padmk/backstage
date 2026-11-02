// Every request that touches an app resolves it, passes the gate, and proves the process is still the
// one approved, because a pid can be reused while the user reads the window.

import AppKit
import HelperLink
import ApplicationServices

private let settleSeconds = 1.0
private let launchTimeoutSeconds = 20
private let pressActions = ["AXPress", "AXConfirm", "AXPick", "AXOpen"]
private let maxRememberedReads = 32
private let singleLineRoles: Set<String> = [kAXTextFieldRole, kAXComboBoxRole, "AXSearchField"]
private let secureSubrole = "AXSecureTextField"

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

private func resolve(_ query: String) throws -> AppIdentity {
  let apps = visibleApps()
  let lowered = query.lowercased()
  let match = apps.first { $0.bundleIdentifier?.lowercased() == lowered }
    ?? apps.first { $0.localizedName?.lowercased() == lowered }
    ?? Int(query).flatMap { pid in apps.first { Int($0.processIdentifier) == pid } }
  guard let match else {
    throw HelperError(code: "app_not_found", message: "\(query) is not running. Use launch_app first.")
  }
  return identity(of: match)
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

private func launch(_ query: String, session: ApprovalSession, connection: Connection) throws -> JSON {
  let url = try installedApp(query)
  guard let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier else {
    throw HelperError(code: "app_not_found", message: "\(query) has no bundle identifier.")
  }
  let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
  try ApprovalGate.require(
    AppIdentity(pid: 0, bundleId: bundleId, name: name, launchDate: nil, path: url.path), session: session, connection: connection)

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
  guard done.wait(timeout: .now() + .seconds(launchTimeoutSeconds)) == .success else {
    throw HelperError(code: "timeout", message: "\(name) did not start in time.")
  }
  if let failure { throw HelperError(code: "action_failed", message: failure.localizedDescription) }
  guard let launched else { throw HelperError(code: "action_failed", message: "\(name) did not start.") }
  return describe(launched)
}

private func activate(_ app: AppIdentity) throws -> JSON {
  guard let path = app.path else { throw HelperError(code: "action_failed", message: "\(app.name) has no location.") }
  let configuration = NSWorkspace.OpenConfiguration()
  configuration.activates = true
  NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) { _, _ in }
  sleep(seconds: 0.4)
  let active = onMain { NSRunningApplication(processIdentifier: app.pid)?.isActive ?? false }
  return ["active": active]
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

private func readTree(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> (header: String, tree: RenderedTree) {
  let application = try applicationElement(app)
  let maxElements = min(max(params["max_elements"] as? Int ?? defaultMaxElements, 1), 5000)
  var roots: [AXUIElement]
  var selected: AXUIElement?
  if let number = params["root"] as? Int {
    roots = [try session.table.element(number, pid: app.pid)]
  } else if params["menu_bar"] as? Bool == true, let menu = attribute(application, kAXMenuBarAttribute) {
    roots = [menu as! AXUIElement]
  } else {
    selected = try selectWindow(application, params: params)
    roots = [selected!] + openMenus(of: application)
  }
  return (header(app: app, application: application, selected: selected),
          renderTree(roots: roots, pid: app.pid, table: session.table, maxElements: maxElements))
}

// Runs an action, then reports what changed in the app's last read, so the agent sees the effect and no
// action claims a success it did not observe.
private func acting(app: AppIdentity, session: ApprovalSession, _ action: () throws -> JSON) throws -> JSON {
  var result = try action()
  guard let last = session.lock.withLock({ session.lastReads[app.pid] }) else {
    result["state"] = ["unknown": true, "reason": "Nothing was read before this action, so changes cannot be reported."] as JSON
    return result
  }
  let deadline = Date().addingTimeInterval(settleSeconds)
  var after = last.lines
  repeat {
    sleep(seconds: 0.1)
    let read: RenderedTree
    do {
      read = try readTree(app: app, params: last.request, session: session).tree
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
  session.lock.withLock { session.lastReads[app.pid] = LastRead(request: last.request, lines: after) }
  return result
}

private func press(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  let element = try session.table.element(integer(params, "element"), pid: app.pid)
  let available = actions(of: element)
  if let name = params["action"] as? String {
    let action = name.hasPrefix("AX") ? name : "AX\(name)"
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
  try postClick(at: CGPoint(x: box.midX, y: box.midY), pid: app.pid, count: 1)
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
  if CFEqual(before, value) || valueChanges(of: element, from: before) { return ["delivery": "accessibility", "verified": true] }
  throw HelperError(code: "outcome_unknown", message: "The app accepted the value, but the element still shows the old one. Read the state before trying again.")
}

// Apps may apply a change a moment after accepting it.
private func valueChanges(of element: AXUIElement, from before: AnyObject?) -> Bool {
  for _ in 0..<6 {
    if !CFEqual(attribute(element, kAXValueAttribute), before) { return true }
    sleep(seconds: 0.05)
  }
  return false
}

// Each route ends the request once text may have arrived, so nothing is inserted twice.
private func typeText(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  let text = try string(params, "text")
  guard !text.isEmpty else { throw HelperError(code: "invalid_request", message: "text is empty.") }
  guard let number = params["element"] as? Int else {
    try postText(text, pid: app.pid)
    return ["delivery": "key_events", "verified": false]
  }
  let element = try session.table.element(number, pid: app.pid)
  let isSecure = stringAttribute(element, kAXSubroleAttribute) == secureSubrole
  let isSingleLine = isSecure || singleLineRoles.contains(stringAttribute(element, kAXRoleAttribute) ?? "")
  // Return would submit the form instead of breaking the line.
  if isSingleLine, text.contains(where: \.isNewline) {
    throw HelperError(code: "invalid_request", message: "This field holds one line. Use press_key with return to submit it.")
  }

  let before = isSecure ? nil : textAttribute(element, kAXValueAttribute)
  if let before {
    // An unfocused text field answers success to this and changes nothing, so the value is checked.
    if isSettable(element, kAXSelectedTextAttribute),
      AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as NSString) == .success {
      if textAttribute(element, kAXSelectedTextAttribute) == text || valueChanges(of: element, from: before as NSString) {
        return ["delivery": "accessibility", "verified": true]
      }
    }
    // Only plain one-line fields: writing the value of a document would lose its formatting.
    if isSingleLine, isSettable(element, kAXValueAttribute) {
      let appended = before + text
      if AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, appended as NSString) == .success {
        if valueChanges(of: element, from: before as NSString) {
          return ["delivery": "value_appended_at_end", "verified": true]
        }
        throw HelperError(code: "outcome_unknown", message: "The app accepted the text, but the field still shows the old value. Read the state before trying again.")
      }
    }
  }

  // Keys go wherever the app's focus is, so they are sent only once it is on this element.
  AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
  sleep(seconds: 0.05)
  let focused = attribute(AXUIElementCreateApplication(app.pid), kAXFocusedUIElementAttribute)
  guard let focused, CFEqual(focused, element) else {
    throw HelperError(code: "action_failed", message: "Could not focus this element, so nothing was typed.")
  }
  try postText(text, pid: app.pid)
  let verified = before.map { valueChanges(of: element, from: $0 as NSString) } ?? false
  return ["delivery": "key_events", "verified": verified]
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
  try postScroll(at: CGPoint(x: box.midX, y: box.midY), pid: app.pid, lines: Int32((forward ? -10 : 10) * pages))
  return ["delivery": "pointer_event", "verified": false]
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
  try postClick(at: CGPoint(x: box.minX + x, y: box.minY + y), pid: app.pid, count: params["count"] as? Int ?? 1)
  return ["delivery": "pointer_event", "verified": false, "window": stringAttribute(window, kAXTitleAttribute) ?? ""]
}

func handle(method: String, params: JSON, connection: Connection) throws -> Any {
  let session = connection.session
  switch method {
  case "hello":
    session.lock.withLock {
      session.clientName = params["client_name"] as? String
      session.language = params["language"] as? String
    }
    return ["version": Configuration.buildVersion, "build": ownBuildIdentity] as JSON

  case "status":
    return ["accessibility": AXIsProcessTrusted(), "screen_recording": CGPreflightScreenCaptureAccess(), "version": Configuration.buildVersion] as JSON

  case "request_permissions":
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let accessibility = AXIsProcessTrustedWithOptions(options)
    let screen = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
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
    return ["revoked": try ApprovalStore.revoke(bundleId: string(params, "bundle_id"))] as JSON

  case "list_apps":
    return ["apps": visibleApps().map(describe)] as JSON

  case "launch_app":
    return try launch(string(params, "app"), session: session, connection: connection)

  default:
    break
  }

  guard ["activate_app", "get_window_state", "screenshot", "press", "set_value", "type_text", "press_key", "scroll", "click_at"].contains(method) else {
    throw HelperError(code: "unknown_method", message: "Unknown method \(method).")
  }

  let app = try resolve(string(params, "app"))
  try ApprovalGate.require(app, session: session, connection: connection)
  try requireSameProcess(app)
  try connection.throwIfCancelled()

  switch method {
  case "activate_app":
    return try activate(app)

  case "get_window_state":
    let read = try readTree(app: app, params: params, session: session)
    session.lock.withLock {
      if session.lastReads.count >= maxRememberedReads { session.lastReads.removeAll() }
      session.lastReads[app.pid] = LastRead(request: params, lines: read.tree.lines)
    }
    var text = read.header + "\n" + read.tree.lines.joined(separator: "\n")
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
      try postKey(key, pid: app.pid)
      return ["delivery": "key_events", "verified": false]
    }

  case "scroll":
    try requireAccessibility()
    return try acting(app: app, session: session) { try scroll(app: app, params: params, session: session) }

  default:
    try requireAccessibility()
    return try acting(app: app, session: session) { try clickAt(app: app, params: params) }
  }
}
