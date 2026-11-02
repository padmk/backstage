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
