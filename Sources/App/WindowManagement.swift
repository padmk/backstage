// Windows as objects: listing them across apps and displays, moving, resizing and arranging them, minimizing,
// full screen, hiding apps, and closing windows or quitting apps. Accessibility makes every change and reads it
// back; the window server supplies what Accessibility cannot see (windows of apps not on the list, other Spaces,
// a locked screen). Coordinates are global points with the origin at the top left of the main display, as
// Accessibility and the window server use them.

import AppKit
import ApplicationServices

// A frame counts as reached within this many points; apps round and clamp.
private let frameTolerance: CGFloat = 2
private let settleSeconds = 1.0
private let quitSeconds = 10.0
private let closeSeconds = 3.0

// The requests that change windows or apps as a whole; each one acts on one app, like the element actions.
let windowMethods: Set<String> = ["set_window", "set_app_state", "close"]

// MARK: Displays

struct Display {
  let id: CGDirectDisplayID
  let name: String
  let frame: CGRect
  // Without the menu bar and the Dock.
  let visible: CGRect
  let main: Bool
}

// NSScreen measures from the bottom left of the main display; windows are placed from its top left.
func displays() -> [Display] {
  onMain {
    let screens = NSScreen.screens
    guard let primaryHeight = screens.first?.frame.height else { return [] }
    let flip = { (rect: CGRect) in CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height) }
    return screens.compactMap { screen in
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
      return Display(id: CGDirectDisplayID(number.uint32Value), name: screen.localizedName, frame: flip(screen.frame),
                     visible: flip(screen.visibleFrame), main: screen == screens.first)
    }
  }
}

private func displayContaining(_ rect: CGRect, in all: [Display]) -> Display? {
  let center = CGPoint(x: rect.midX, y: rect.midY)
  return all.first { $0.frame.contains(center) } ?? all.max { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }
}

private extension CGRect {
  var area: CGFloat { isNull ? 0 : width * height }
  var json: [Int] { [wholePoints(minX), wholePoints(minY), wholePoints(width), wholePoints(height)] }
}

private func describe(_ display: Display) -> JSON {
  ["id": Int(display.id), "name": display.name, "frame": display.frame.json, "visible": display.visible.json, "main": display.main]
}

// MARK: Listing

private struct ServerWindow {
  let id: CGWindowID
  let pid: pid_t
  let frame: CGRect
  let onScreen: Bool
  let order: Int
  // Known only with Screen Recording, and only used to tell a document window from an app's own helper windows.
  let named: Bool
}

// The ordinary windows (layer 0) the window server knows, front to back.
private func serverWindows() -> [ServerWindow] {
  let all = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
  return all.enumerated().compactMap { order, info in
    guard info[kCGWindowLayer as String] as? Int == 0,
      let id = info[kCGWindowNumber as String] as? CGWindowID,
      let pid = info[kCGWindowOwnerPID as String] as? pid_t,
      let box = info[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: box as CFDictionary),
      frame.width > 1, frame.height > 1
    else { return nil }
    return ServerWindow(id: id, pid: pid, frame: frame, onScreen: info[kCGWindowIsOnscreen as String] as? Bool == true, order: order,
                        named: !((info[kCGWindowName as String] as? String) ?? "").isEmpty)
  }
}

private func axWindowsById(_ pid: pid_t) -> [CGWindowID: AXUIElement] {
  var found: [CGWindowID: AXUIElement] = [:]
  for window in windows(of: AXUIElementCreateApplication(pid)) {
    if let number = windowNumber(of: window) { found[number] = window }
  }
  return found
}

private func isModal(_ window: AXUIElement) -> Bool {
  boolAttribute(window, "AXModal") || ((attribute(window, kAXChildrenAttribute) as? [AXUIElement]) ?? []).contains {
    stringAttribute($0, kAXRoleAttribute) == "AXSheet"
  }
}

// Every app's windows, or one app's. Titles and what can be done come only for apps on the user's list; for the
// others, an agent sees that a window is there and where, never what it shows.
func listWindows(params: JSON) throws -> JSON {
  let locked = isScreenLocked()
  let only = try (params["app"] as? String).map { try resolve($0) }
  let apps = onMain { Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a }) }
  let allDisplays = displays()
  let trusted = AXIsProcessTrusted()
  let namesKnown = CGPreflightScreenCaptureAccess()
  var enriched: [pid_t: [CGWindowID: AXUIElement]] = [:]
  var entries: [JSON] = []
  for window in serverWindows() {
    guard let running = apps[window.pid], running.activationPolicy != .prohibited else { continue }
    if let only, window.pid != only.pid { continue }
    // Apps keep windows that are no documents (toolbars, tab bars, offscreen buffers). One that is not drawn now
    // counts only when it has a name (a window on another Space has one) or, without Screen Recording to tell,
    // when it is large enough to be a document.
    if !window.onScreen, namesKnown ? !window.named : window.frame.height < 60 {
      if !(trusted && !locked && axWindowsById(window.pid)[window.id] != nil) { continue }
    }
    let app = identity(of: running)
    let access = ApprovalGate.access(app)
    var entry: JSON = [
      "id": Int(window.id), "app": app.name, "bundle_id": app.bundleId, "access": access.rawValue,
      "frame": window.frame.json, "front_index": window.order, "on_screen": window.onScreen,
      "app_hidden": running.isHidden,
    ]
    if let display = displayContaining(window.frame, in: allDisplays) { entry["display"] = Int(display.id) }
    if access == .allowed, trusted, !locked {
      if enriched[window.pid] == nil { enriched[window.pid] = axWindowsById(window.pid) }
      if let element = enriched[window.pid]?[window.id] {
        entry["title"] = clamped(stringAttribute(element, kAXTitleAttribute) ?? "")
        entry["minimized"] = boolAttribute(element, kAXMinimizedAttribute)
        entry["fullscreen"] = boolAttribute(element, "AXFullScreen")
        entry["modal"] = isModal(element)
        entry["movable"] = isSettable(element, kAXPositionAttribute)
        entry["resizable"] = isSettable(element, kAXSizeAttribute)
        // The app's own number for it, as get_window_state and screenshot take it.
        if let index = windows(of: AXUIElementCreateApplication(window.pid)).firstIndex(where: { CFEqual($0, element) }) { entry["window"] = index }
        // Not minimized, not hidden, yet not drawn: most likely on another Space.
        entry["space"] = window.onScreen ? "current" : (boolAttribute(element, kAXMinimizedAttribute) || running.isHidden ? "unknown" : "other")
      } else {
        // Accessibility sees only the current Space's windows, so one it does not list is elsewhere or not a document window.
        entry["space"] = window.onScreen ? "current" : "unknown"
      }
    } else {
      entry["space"] = window.onScreen ? "current" : "unknown"
    }
    entries.append(entry)
  }
  var result: JSON = ["displays": allDisplays.map(describe), "windows": entries, "screen_locked": locked]
  if let front = onMain({ NSWorkspace.shared.frontmostApplication }) { result["front_app"] = front.localizedName ?? front.bundleIdentifier ?? "" }
  if locked { result["note"] = "The screen is locked, so windows come from the window server only: no titles or states." }
  return result
}

// MARK: Finding one window

// By the id from list_windows, checked against the app that owns it, or by the app's own window number.
func targetWindow(app: AppIdentity, params: JSON) throws -> AXUIElement {
  let application = try applicationElement(app)
  if let given = params["id"] as? Int {
    guard let id = CGWindowID(exactly: given) else { throw HelperError(code: "invalid_request", message: "id is a window id from list_windows.") }
    if let element = axWindowsById(app.pid)[id] { return element }
    let owner = serverWindows().first { $0.id == id }
    if let owner, owner.pid != app.pid {
      throw HelperError(code: "stale_window", message: "Window \(id) belongs to another app. List the windows again.")
    }
    throw HelperError(code: "window_not_found", message: owner == nil
      ? "There is no window \(id) any more. List the windows again."
      : "Window \(id) is not reachable now, for example because it is on another Space. Switch to its Space, or work with a window on this one.")
  }
  return try selectWindow(application, params: params)
}

private func reference(_ window: AXUIElement) -> JSON {
  var entry: JSON = [:]
  if let number = windowNumber(of: window) { entry["id"] = Int(number) }
  if let title = stringAttribute(window, kAXTitleAttribute) { entry["title"] = clamped(title) }
  return entry
}

// MARK: Changing a window

private func axValue(_ point: CGPoint) -> AXValue {
  var value = point
  return AXValueCreate(.cgPoint, &value)!
}

private func axValue(_ size: CGSize) -> AXValue {
  var value = size
  return AXValueCreate(.cgSize, &value)!
}

private func nearlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
  abs(a.minX - b.minX) <= frameTolerance && abs(a.minY - b.minY) <= frameTolerance
    && abs(a.width - b.width) <= frameTolerance && abs(a.height - b.height) <= frameTolerance
}

// Where a layout puts a window on a display's visible area.
func layoutFrame(_ name: String, current: CGRect, on area: CGRect) throws -> CGRect {
  let x = area.minX, y = area.minY, w = area.width, h = area.height
  switch name {
  case "maximize": return area
  case "center":
    let width = min(current.width, w), height = min(current.height, h)
    return CGRect(x: x + (w - width) / 2, y: y + (h - height) / 2, width: width, height: height)
  case "left_half": return CGRect(x: x, y: y, width: w / 2, height: h)
  case "right_half": return CGRect(x: x + w / 2, y: y, width: w / 2, height: h)
  case "top_half": return CGRect(x: x, y: y, width: w, height: h / 2)
  case "bottom_half": return CGRect(x: x, y: y + h / 2, width: w, height: h / 2)
  case "top_left": return CGRect(x: x, y: y, width: w / 2, height: h / 2)
  case "top_right": return CGRect(x: x + w / 2, y: y, width: w / 2, height: h / 2)
  case "bottom_left": return CGRect(x: x, y: y + h / 2, width: w / 2, height: h / 2)
  case "bottom_right": return CGRect(x: x + w / 2, y: y + h / 2, width: w / 2, height: h / 2)
  case "left_third": return CGRect(x: x, y: y, width: w / 3, height: h)
  case "center_third": return CGRect(x: x + w / 3, y: y, width: w / 3, height: h)
  case "right_third": return CGRect(x: x + 2 * w / 3, y: y, width: w / 3, height: h)
  case "left_two_thirds": return CGRect(x: x, y: y, width: 2 * w / 3, height: h)
  case "right_two_thirds": return CGRect(x: x + w / 3, y: y, width: 2 * w / 3, height: h)
  default: throw HelperError(code: "invalid_request", message: "Unknown layout \(name).")
  }
}

private func targetDisplay(_ choice: Any?, current: CGRect) throws -> Display {
  let all = displays()
  guard let here = displayContaining(current, in: all) ?? all.first else {
    throw HelperError(code: "action_failed", message: "No display was found.")
  }
  switch choice {
  case nil: return here
  case let text as String where text == "next" || text == "previous":
    guard let index = all.firstIndex(where: { $0.id == here.id }) else { return here }
    return all[(index + (text == "next" ? 1 : all.count - 1)) % all.count]
  case let number as Int:
    guard let id = CGDirectDisplayID(exactly: number), let display = all.first(where: { $0.id == id }) else {
      throw HelperError(code: "invalid_request", message: "There is no display \(number). list_windows lists them.")
    }
    return display
  default:
    throw HelperError(code: "invalid_request", message: "display is a display id from list_windows, next or previous.")
  }
}

// Position, then size, then position again: an app may refuse a size that does not fit where the window is, or
// move the window while it resizes. Then read back until the frame holds still.
private func setFrame(_ window: AXUIElement, to target: CGRect) throws -> JSON {
  guard isSettable(window, kAXPositionAttribute) || isSettable(window, kAXSizeAttribute) else {
    throw HelperError(code: "not_settable", message: "This window cannot be moved or resized.")
  }
  let before = frame(of: window)
  if isSettable(window, kAXPositionAttribute) { try setAXAttribute(window, kAXPositionAttribute, axValue(target.origin)) }
  if isSettable(window, kAXSizeAttribute) { try setAXAttribute(window, kAXSizeAttribute, axValue(target.size)) }
  if isSettable(window, kAXPositionAttribute) { try setAXAttribute(window, kAXPositionAttribute, axValue(target.origin)) }
  var after = frame(of: window)
  let started = Date()
  while Date().timeIntervalSince(started) < settleSeconds {
    sleep(seconds: 0.1)
    let now = frame(of: window)
    if let now, let previous = after, nearlyEqual(now, previous) { after = now; break }
    after = now
  }
  guard let after else { throw HelperError(code: "outcome_unknown", message: "The window's frame cannot be read back. Read the state before trying again.") }
  var result: JSON = ["delivery": "accessibility", "requested": target.json, "frame": after.json, "verified": nearlyEqual(after, target)]
  if let before { result["before"] = before.json }
  if !nearlyEqual(after, target) {
    let moved = abs(after.minX - target.minX) <= frameTolerance && abs(after.minY - target.minY) <= frameTolerance
    result["adjusted"] = moved ? "size: the app keeps the window within its own minimum or maximum" : "the app placed the window elsewhere"
  }
  return result
}

private func waitFor(_ check: () -> Bool, seconds: Double) -> Bool {
  let started = Date()
  while Date().timeIntervalSince(started) < seconds {
    if check() { return true }
    sleep(seconds: 0.1)
  }
  return check()
}

// The frame set_window asks for, refused unless every value is a plausible screen coordinate in points.
func requestedFrame(_ value: Any?) throws -> CGRect {
  guard let box = value as? JSON, let x = (box["x"] as? NSNumber)?.doubleValue, let y = (box["y"] as? NSNumber)?.doubleValue,
    let width = (box["width"] as? NSNumber)?.doubleValue, let height = (box["height"] as? NSNumber)?.doubleValue,
    width > 0, height > 0, isPlausibleGeometry(CGRect(x: x, y: y, width: width, height: height))
  else {
    throw HelperError(code: "invalid_request",
                      message: "frame takes x, y, width and height in points, with a positive width and height and no value beyond \(Int(maxScreenCoordinate)).")
  }
  return CGRect(x: x, y: y, width: width, height: height)
}

// One change per call. Bringing a window back from the Dock or into full screen puts it in front, so those need
// the caller's foreground consent, and the app the user was in gets the focus back.
func setWindow(app: AppIdentity, params: JSON) throws -> JSON {
  let window = try targetWindow(app: app, params: params)
  let changes = ["frame", "layout", "minimized", "fullscreen"].filter { params[$0] != nil }
  guard changes.count == 1, let change = changes.first else {
    throw HelperError(code: "invalid_request", message: "Give exactly one of frame, layout, minimized or fullscreen.")
  }
  let foreground = params["foreground"] as? Bool == true
  var result: JSON
  switch change {
  case "frame":
    let target = try requestedFrame(params["frame"])
    guard displays().contains(where: { $0.frame.intersects(target) }) else {
      throw HelperError(code: "invalid_request", message: "That frame lies on no display. list_windows lists the displays.")
    }
    result = try setFrame(window, to: target)
  case "layout":
    let name = try string(params, "layout")
    guard let current = frame(of: window) else { throw HelperError(code: "action_failed", message: "The window has no frame.") }
    let display = try targetDisplay(params["display"], current: current)
    result = try setFrame(window, to: try layoutFrame(name, current: current, on: display.visible))
    result["display"] = Int(display.id)
  case "minimized":
    let wanted = params["minimized"] as? Bool == true
    if !wanted, !foreground {
      throw HelperError(code: "needs_foreground", message: "Bringing a window back from the Dock puts it in front of the user's work. Pass foreground: true to do it anyway, and tell the user.")
    }
    guard isSettable(window, kAXMinimizedAttribute) else { throw HelperError(code: "not_settable", message: "This window cannot be minimized.") }
    let front = onMain { NSWorkspace.shared.frontmostApplication }
    try setAXAttribute(window, kAXMinimizedAttribute, wanted as CFBoolean)
    let reached = waitFor({ boolAttribute(window, kAXMinimizedAttribute) == wanted }, seconds: settleSeconds)
    result = ["delivery": "accessibility", "minimized": boolAttribute(window, kAXMinimizedAttribute), "verified": reached]
    if !wanted, returnFocus(to: front, from: app.pid) { result["focus_returned"] = true }
  default:
    let wanted = params["fullscreen"] as? Bool == true
    guard foreground else {
      throw HelperError(code: "needs_foreground", message: "Full screen moves the window to a Space of its own and switches to it. Pass foreground: true to do it anyway, and tell the user.")
    }
    guard isSettable(window, "AXFullScreen") else { throw HelperError(code: "not_settable", message: "This window has no full screen.") }
    try setAXAttribute(window, "AXFullScreen", wanted as CFBoolean)
    let reached = waitFor({ boolAttribute(window, "AXFullScreen") == wanted }, seconds: 3)
    result = ["delivery": "accessibility", "fullscreen": boolAttribute(window, "AXFullScreen"), "verified": reached]
  }
  result["window"] = reference(window)
  return result
}

// MARK: Apps

// Hiding and showing go through the app, so they work without its windows; showing never brings it forward.
func setAppState(app: AppIdentity, params: JSON) throws -> JSON {
  let state = try string(params, "state")
  guard let running = onMain({ NSRunningApplication(processIdentifier: app.pid) }) else {
    throw HelperError(code: "app_not_found", message: "\(app.name) is no longer running.")
  }
  let hide: Bool
  switch state {
  case "hidden": hide = true
  case "shown": hide = false
  default: throw HelperError(code: "invalid_request", message: "state is hidden or shown.")
  }
  let front = onMain { NSWorkspace.shared.frontmostApplication }
  try beginEffect()
  _ = onMain { hide ? running.hide() : running.unhide() }
  let reached = waitFor({ onMain { running.isHidden } == hide }, seconds: settleSeconds)
  var result: JSON = ["delivery": "app", "hidden": onMain { running.isHidden }, "verified": reached]
  if !hide, returnFocus(to: front, from: app.pid) { result["focus_returned"] = true }
  return result
}

// MARK: Closing

// What is known of a window after its close button was pressed.
struct WindowAfterClose {
  var wasOnScreen: Bool
  var inWindowServer: Bool
  var onScreen: Bool
  // Whether the app still lists it among its windows; nil when the app's list cannot be read.
  var inAccessibility: Bool?
  var minimized: Bool
  var appHidden: Bool
}

// Many apps keep a closed window in the window server, hidden, so leaving the window server is not the only sign.
// A window the app no longer lists has closed: the app lists its minimized windows and those of the current Space,
// where the window was when it was pressed. A window that was drawn and no longer is has closed too, unless it was
// minimized meanwhile. An app hidden meanwhile stops drawing its windows, so then only the window server counts.
func windowHasClosed(_ window: WindowAfterClose) -> Bool {
  if !window.inWindowServer { return true }
  if window.appHidden { return false }
  if window.inAccessibility == false { return true }
  return window.wasOnScreen && !window.onScreen && !window.minimized
}

// A window closes through its close button; an app quits as if the user chose Quit. Either may stop to ask about
// unsaved work, which the agent then reads; nothing is ever forced.
func closeWindowOrApp(app: AppIdentity, params: JSON) throws -> JSON {
  if params["quit"] as? Bool == true {
    guard params["window"] == nil, params["id"] == nil else {
      throw HelperError(code: "invalid_request", message: "Give a window, or quit: true, not both.")
    }
    guard let running = onMain({ NSRunningApplication(processIdentifier: app.pid) }) else {
      return ["delivery": "app", "quit": true, "verified": true]
    }
    try beginEffect()
    _ = onMain { running.terminate() }
    if waitFor({ onMain { running.isTerminated } }, seconds: quitSeconds) {
      return ["delivery": "app", "quit": true, "verified": true]
    }
    throw HelperError(code: "outcome_unknown", message: "\(app.name) has not quit; it may be asking about unsaved work. Read its windows before trying again.")
  }
  let window = try targetWindow(app: app, params: params)
  let number = windowNumber(of: window)
  guard let button = elementAttribute(window, kAXCloseButtonAttribute) else {
    throw HelperError(code: "not_settable", message: "This window has no close button.")
  }
  let reference = reference(window)
  let wasOnScreen = number.map { id in serverWindows().contains { $0.id == id && $0.onScreen } } ?? false
  let application = try applicationElement(app)
  let outcome = try performAXAction(button, kAXPressAction)
  guard outcome == .success else { throw axFailure(outcome, "pressing the close button") }
  let gone = waitFor({
    guard let id = number else { return false }
    let server = serverWindows().first { $0.id == id }
    // While the screen is locked, or when the app does not answer, its window list says nothing.
    let listed = isScreenLocked() ? nil : (attribute(application, kAXWindowsAttribute) as? [AXUIElement])
    let running = onMain { NSRunningApplication(processIdentifier: app.pid) }
    return windowHasClosed(WindowAfterClose(
      wasOnScreen: wasOnScreen, inWindowServer: server != nil, onScreen: server?.onScreen == true,
      inAccessibility: listed.map { $0.contains { CFEqual($0, window) } },
      minimized: boolAttribute(window, kAXMinimizedAttribute), appHidden: running?.isHidden == true))
  }, seconds: closeSeconds)
  if gone { return ["delivery": "accessibility", "closed": reference, "verified": true] }
  if isModal(window) {
    throw HelperError(code: "outcome_unknown", message: "The window asks about unsaved work instead of closing. Read it with get_window_state and answer, or tell the user.")
  }
  throw HelperError(code: "outcome_unknown", message: "The window has not closed. Read the state before trying again.")
}
