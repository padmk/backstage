// Keyboard and mouse events addressed to one process. They never go to the global event stream, so they
// cannot reach another app and do not move the cursor. No API gives proof of delivery.

import AppKit
import Carbon.HIToolbox

private let namedKeys: [String: CGKeyCode] = [
  "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
  "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
  "forwarddelete": 117,
  "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
  "f11": 103, "f12": 111,
]

private let modifierFlags: [String: CGEventFlags] = [
  "cmd": .maskCommand, "command": .maskCommand, "super": .maskCommand,
  "ctrl": .maskControl, "control": .maskControl,
  "alt": .maskAlternate, "option": .maskAlternate,
  "shift": .maskShift,
]

// Maps characters to physical keys on the current layout, so cmd+z means z on QWERTZ too.
private func characterKeys() -> [String: CGKeyCode] {
  guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
    let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
  else { return [:] }
  let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
  var map: [String: CGKeyCode] = [:]
  data.withUnsafeBytes { buffer in
    guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
    for code in UInt16(0)..<UInt16(51) {
      var deadKeys: UInt32 = 0
      var characters = [UniChar](repeating: 0, count: 4)
      var length = 0
      let status = UCKeyTranslate(
        layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &characters)
      guard status == noErr, length > 0 else { continue }
      let text = String(utf16CodeUnits: characters, count: length).lowercased()
      if map[text] == nil { map[text] = code }
    }
  }
  return map
}

func keyCode(named name: String) -> CGKeyCode? {
  namedKeys[name] ?? onMain { characterKeys() }[name]
}

func postKey(_ combination: String, pid: pid_t) throws {
  let parts = combination.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
  let keyName = combination.hasSuffix("+") ? "+" : (parts.last ?? "")
  let modifiers = combination.hasSuffix("+") ? parts.dropLast(2) : parts.dropLast()
  guard let code = keyCode(named: keyName) else {
    throw HelperError(code: "invalid_key", message: "Unknown key \(keyName) in \(combination).")
  }
  var flags: CGEventFlags = []
  for name in modifiers {
    guard let flag = modifierFlags[name] else {
      throw HelperError(code: "invalid_key", message: "Unknown modifier \(name).")
    }
    flags.insert(flag)
  }
  for down in [true, false] {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
      throw HelperError(code: "action_failed", message: "Could not create a key event.")
    }
    event.flags = flags
    event.postToPid(pid)
  }
}

func postText(_ text: String, pid: pid_t) throws {
  for character in text {
    let units = Array(String(character).utf16)
    for down in [true, false] {
      guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else {
        throw HelperError(code: "action_failed", message: "Could not create a key event.")
      }
      event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
      // Otherwise the event carries the keys the user is holding, and a letter typed while they hold Cmd
      // reaches the app as a shortcut.
      event.flags = []
      event.postToPid(pid)
    }
  }
}

// Where a pointer event goes in a window the app is not showing in front.
struct PointerTarget {
  let window: CGWindowID?
  let origin: CGPoint
}

// The window server routes a pointer event by what is under the real cursor unless the event names its
// window, so these fields are what lets it reach a background window without moving the cursor. Flags are
// set explicitly, because the event would otherwise carry whatever keys the user is holding.
private func route(_ event: CGEvent, point: CGPoint, target: PointerTarget, pid: pid_t, extra: [(UInt32, Int64)]) {
  event.flags = []
  guard let window = target.window else { return }
  setEventWindowLocation?(event, CGPoint(x: point.x - target.origin.x, y: point.y - target.origin.y))
  let number = Int64(window)
  for (field, value) in [(40, Int64(pid)), (51, number), (91, number), (92, number)] + extra {
    if let name = CGEventField(rawValue: field) { event.setIntegerValueField(name, value: value) }
  }
}

private func clickFields(state: Int64, gesture: Int64) -> [(UInt32, Int64)] {
  [(1, state), (3, 0), (7, touchSubtype), (58, gesture)]
}

// A window that never saw a move has stale tracking state and ignores the event that follows.
private func postMove(to point: CGPoint, source: CGEventSource?, target: PointerTarget, pid: pid_t, gesture: Int64) throws {
  guard let moved = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
    throw HelperError(code: "action_failed", message: "Could not create a mouse event.")
  }
  route(moved, point: point, target: target, pid: pid, extra: clickFields(state: 0, gesture: gesture))
  post(moved, to: pid)
  sleep(seconds: pointerEventGap)
}

func postClick(at point: CGPoint, target: PointerTarget, pid: pid_t, count: Int) throws {
  let source = CGEventSource(stateID: .hidSystemState)
  let gesture = Int64.random(in: 1...Int64(Int32.max))
  try postMove(to: point, source: source, target: target, pid: pid, gesture: gesture)
  for click in 1...min(max(1, count), 3) {
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
      guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
        throw HelperError(code: "action_failed", message: "Could not create a mouse event.")
      }
      route(event, point: point, target: target, pid: pid, extra: clickFields(state: Int64(click), gesture: gesture))
      post(event, to: pid)
      sleep(seconds: pointerEventGap)
    }
  }
}

private let dragSteps = 12

// A press, a path of drag events and a release, all addressed to the window like a click, so a background
// window takes it without the cursor moving.
func postDrag(from start: CGPoint, to end: CGPoint, target: PointerTarget, pid: pid_t) throws {
  let source = CGEventSource(stateID: .hidSystemState)
  let gesture = Int64.random(in: 1...Int64(Int32.max))
  try postMove(to: start, source: source, target: target, pid: pid, gesture: gesture)
  let path = (0...dragSteps).map { step -> CGPoint in
    let progress = CGFloat(step) / CGFloat(dragSteps)
    return CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
  }
  let events: [(CGEventType, CGPoint)] = [(.leftMouseDown, start)] + path.dropFirst().map { (.leftMouseDragged, $0) } + [(.leftMouseUp, end)]
  for (type, point) in events {
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
      throw HelperError(code: "action_failed", message: "Could not create a mouse event.")
    }
    route(event, point: point, target: target, pid: pid, extra: clickFields(state: 1, gesture: gesture))
    post(event, to: pid)
    sleep(seconds: pointerEventGap)
  }
}

func postScroll(at point: CGPoint, target: PointerTarget, pid: pid_t, lines: Int32) throws {
  let source = CGEventSource(stateID: .hidSystemState)
  try postMove(to: point, source: source, target: target, pid: pid, gesture: Int64.random(in: 1...Int64(Int32.max)))
  guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else {
    throw HelperError(code: "action_failed", message: "Could not create a scroll event.")
  }
  event.location = point
  route(event, point: point, target: target, pid: pid, extra: [])
  post(event, to: pid)
}

// The last resort for a window that ignores background input: the app comes forward, the click goes through
// the real cursor, and the cursor goes back to where it was. The caller gives the focus back.
// A click posted to the whole system lands on whatever window is on top at that point, which may belong to
// another app or be the approval window itself. It is refused unless the top window there is the app's own.
private func requireOwnWindowOnTop(at point: CGPoint, pid: pid_t) throws {
  let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
  let top = windows.first { info in
    guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
      (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
    else { return false }
    return rect.contains(point)
  }
  guard let top, (top[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == pid else {
    let owner = top?[kCGWindowOwnerName as String] as? String ?? "another window"
    throw HelperError(code: "point_covered", message: "\(owner) is on top at that point, so nothing was clicked.")
  }
}

func postForegroundClick(at point: CGPoint, window: AXUIElement, pid: pid_t, count: Int) throws {
  guard let app = NSRunningApplication(processIdentifier: pid) else {
    throw HelperError(code: "app_not_found", message: "The app is no longer running.")
  }
  _ = onMain { app.activate() }
  AXUIElementPerformAction(window, kAXRaiseAction as CFString)
  let deadline = Date().addingTimeInterval(1)
  while onMain({ NSWorkspace.shared.frontmostApplication?.processIdentifier }) != pid, Date() < deadline {
    sleep(seconds: 0.05)
  }
  guard onMain({ NSWorkspace.shared.frontmostApplication?.processIdentifier }) == pid else {
    throw HelperError(code: "action_failed", message: "The app did not come forward, so nothing was clicked.")
  }
  sleep(seconds: 0.15)
  let cursor = CGEvent(source: nil)?.location
  let source = CGEventSource(stateID: .hidSystemState)
  defer {
    if let cursor { CGWarpMouseCursorPosition(cursor) }
    CGAssociateMouseAndMouseCursorPosition(1)
  }
  guard let moved = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
    throw HelperError(code: "action_failed", message: "Could not create a mouse event.")
  }
  moved.flags = []
  try requireOwnWindowOnTop(at: point, pid: pid)
  moved.post(tap: .cghidEventTap)
  sleep(seconds: pointerEventGap)
  for click in 1...min(max(1, count), 3) {
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
      // Checked right before each press, so a window that appeared meanwhile, such as an approval, is not hit.
      if type == .leftMouseDown { try requireOwnWindowOnTop(at: point, pid: pid) }
      guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
        throw HelperError(code: "action_failed", message: "Could not create a mouse event.")
      }
      event.flags = []
      event.setIntegerValueField(.mouseEventClickState, value: Int64(click))
      event.post(tap: .cghidEventTap)
      sleep(seconds: pointerEventGap)
    }
  }
  sleep(seconds: 0.1)
}
