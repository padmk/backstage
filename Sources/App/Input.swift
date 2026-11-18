// Keyboard and mouse events addressed to one process. They never go to the global event stream, so they
// cannot reach another app and do not move the cursor. No API gives proof of delivery.

import AppKit
import Carbon.HIToolbox

private let namedKeys: [String: CGKeyCode] = [
  "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
  "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
  "forwarddelete": 117,
  "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
  "f11": 103, "f12": 111,
]

// In the order menus show them, which is also the order of a combination's text.
enum KeyModifier: String, CaseIterable {
  case ctrl, alt, shift, cmd

  static func named(_ name: String) -> KeyModifier? {
    switch name.lowercased() {
    case "cmd", "command", "super": return .cmd
    case "ctrl", "control": return .ctrl
    case "alt", "option": return .alt
    case "shift": return .shift
    default: return nil
    }
  }

  var flag: CGEventFlags {
    switch self {
    case .cmd: return .maskCommand
    case .ctrl: return .maskControl
    case .alt: return .maskAlternate
    case .shift: return .maskShift
    }
  }
}

// Other names for the same key, so a combination and a menu's shortcut compare equal however they spell it.
private let keyAliases = ["enter": "return", "esc": "escape", "backspace": "delete"]

// A key with the modifiers held for it, parsed from text such as cmd+shift+s or cmd++, where a trailing + is the
// key itself. Key names lose case and underscores, so page_up and pageup are one key.
struct KeyCombination: Equatable {
  let modifiers: Set<KeyModifier>
  let key: String

  init(modifiers: Set<KeyModifier>, key: String) {
    self.modifiers = modifiers
    let name = key.count == 1 ? key.lowercased() : key.lowercased().replacingOccurrences(of: "_", with: "")
    self.key = keyAliases[name] ?? name
  }

  static func parse(_ text: String) throws -> KeyCombination {
    let key: String
    var names: [String]
    if text.hasSuffix("+") {
      key = "+"
      let rest = text.dropLast()
      names = (rest.hasSuffix("+") ? rest.dropLast() : rest).split(separator: "+", omittingEmptySubsequences: false).map(String.init)
      if names == [""] { names = [] }
    } else {
      let parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
      key = parts.last ?? ""
      names = Array(parts.dropLast())
    }
    guard !key.isEmpty else { throw HelperError(code: "invalid_key", message: "No key in \(text).") }
    var modifiers: Set<KeyModifier> = []
    for name in names {
      guard let modifier = KeyModifier.named(name) else {
        throw HelperError(code: "invalid_key", message: "Unknown modifier \(name).")
      }
      modifiers.insert(modifier)
    }
    return KeyCombination(modifiers: modifiers, key: key)
  }

  // Commands and shortcuts of the app's menus answer to it; other keys go to the focused view.
  var isShortcut: Bool { modifiers.contains(.cmd) || modifiers.contains(.ctrl) }

  var flags: CGEventFlags { modifiers.reduce(into: []) { $0.insert($1.flag) } }

  var text: String { (KeyModifier.allCases.filter(modifiers.contains).map(\.rawValue) + [key]).joined(separator: "+") }
}

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

func postKey(_ combination: KeyCombination, app: AppIdentity) throws {
  guard let code = keyCode(named: combination.key) else {
    throw HelperError(code: "invalid_key", message: "Unknown key \(combination.key).")
  }
  let input = ProcessInput(app)
  let start = try beginEffect()
  for down in [true, false] {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
      throw HelperError(code: "action_failed", message: "Could not create a key event.")
    }
    event.flags = combination.flags
    try input.postKey(event, start)
  }
}

func postText(_ text: String, app: AppIdentity) throws {
  let input = ProcessInput(app)
  for (sent, character) in text.enumerated() {
    // A cancel, the deadline or the app quitting stops the typing between characters; what was typed stays, so the
    // outcome is unknown.
    let progress = sent == 0 ? nil : "\(sent) characters were typed"
    let start = try beginEffect(progress: progress)
    let units = Array(String(character).utf16)
    for down in [true, false] {
      guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else {
        throw HelperError(code: "action_failed", message: "Could not create a key event.")
      }
      event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
      // Otherwise the event carries the keys the user is holding, and a letter typed while they hold Cmd
      // reaches the app as a shortcut.
      event.flags = []
      try input.postKey(event, start, progress: progress)
    }
  }
}

// A click's button and the keys held during it, such as cmd for adding to a selection.
struct ClickStyle {
  var button: CGMouseButton = .left
  var flags: CGEventFlags = []

  static func parse(button name: String?, modifiers names: [String]) throws -> ClickStyle {
    var style = ClickStyle()
    switch name ?? "left" {
    case "left": style.button = .left
    case "right": style.button = .right
    case "middle": style.button = .center
    default: throw HelperError(code: "invalid_request", message: "button must be left, right or middle.")
    }
    for name in names {
      guard let modifier = KeyModifier.named(name) else {
        throw HelperError(code: "invalid_key", message: "Unknown modifier \(name).")
      }
      style.flags.insert(modifier.flag)
    }
    return style
  }

  var types: (down: CGEventType, up: CGEventType) {
    switch button {
    case .right: return (.rightMouseDown, .rightMouseUp)
    case .left: return (.leftMouseDown, .leftMouseUp)
    default: return (.otherMouseDown, .otherMouseUp)
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
private func route(_ event: CGEvent, point: CGPoint, target: PointerTarget, pid: pid_t, extra: [(UInt32, Int64)], flags: CGEventFlags = []) {
  event.flags = flags
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
private func postMove(to point: CGPoint, source: CGEventSource?, target: PointerTarget, input: ProcessInput, gesture: Int64, _ start: EffectStart) throws {
  guard let moved = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
    throw HelperError(code: "action_failed", message: "Could not create a mouse event.")
  }
  route(moved, point: point, target: target, pid: input.app.pid, extra: clickFields(state: 0, gesture: gesture))
  try input.postPointer(moved, start)
  sleep(seconds: pointerEventGap)
}

func postClick(at point: CGPoint, target: PointerTarget, app: AppIdentity, count: Int, style: ClickStyle = ClickStyle()) throws {
  let input = ProcessInput(app)
  let source = CGEventSource(stateID: .hidSystemState)
  let gesture = Int64.random(in: 1...Int64(Int32.max))
  // Checked once for the whole gesture, so a press is never left without its release.
  let start = try beginEffect()
  try postMove(to: point, source: source, target: target, input: input, gesture: gesture, start)
  for click in 1...min(max(1, count), 3) {
    for type in [style.types.down, style.types.up] {
      guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: style.button) else {
        throw HelperError(code: "action_failed", message: "Could not create a mouse event.")
      }
      route(event, point: point, target: target, pid: app.pid, extra: clickFields(state: Int64(click), gesture: gesture), flags: style.flags)
      try input.postPointer(event, start)
      sleep(seconds: pointerEventGap)
    }
  }
}

private let dragSteps = 12

// A press, a path of drag events and a release, all addressed to the window like a click, so a background
// window takes it without the cursor moving.
func postDrag(from start: CGPoint, to end: CGPoint, target: PointerTarget, app: AppIdentity) throws {
  let input = ProcessInput(app)
  let source = CGEventSource(stateID: .hidSystemState)
  let gesture = Int64.random(in: 1...Int64(Int32.max))
  let effect = try beginEffect()
  try postMove(to: start, source: source, target: target, input: input, gesture: gesture, effect)
  let path = (0...dragSteps).map { step -> CGPoint in
    let progress = CGFloat(step) / CGFloat(dragSteps)
    return CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
  }
  let events: [(CGEventType, CGPoint)] = [(.leftMouseDown, start)] + path.dropFirst().map { (.leftMouseDragged, $0) } + [(.leftMouseUp, end)]
  for (type, point) in events {
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
      throw HelperError(code: "action_failed", message: "Could not create a mouse event.")
    }
    route(event, point: point, target: target, pid: app.pid, extra: clickFields(state: 1, gesture: gesture))
    try input.postPointer(event, effect)
    sleep(seconds: pointerEventGap)
  }
}

func postScroll(at point: CGPoint, target: PointerTarget, app: AppIdentity, lines: Int32) throws {
  let input = ProcessInput(app)
  let source = CGEventSource(stateID: .hidSystemState)
  let start = try beginEffect()
  try postMove(to: point, source: source, target: target, input: input, gesture: Int64.random(in: 1...Int64(Int32.max)), start)
  guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else {
    throw HelperError(code: "action_failed", message: "Could not create a scroll event.")
  }
  event.location = point
  route(event, point: point, target: target, pid: app.pid, extra: [])
  try input.postPointer(event, start)
}

// The last resort for a window that ignores background input: the app comes forward, the click goes through
// the real cursor, and the cursor goes back to where it was. The caller gives the focus back.
// A click posted to the whole system lands on whatever window is on top at that point, which may belong to
// another app, a Backstage window or another window of the same app. It is refused unless the top window there is
// the one asked for.
private func requireOwnWindowOnTop(at point: CGPoint, pid: pid_t, window: CGWindowID?) throws {
  let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
  if let message = coveringWindowProblem(windows, at: point, pid: pid, window: window) {
    throw HelperError(code: "point_covered", message: message)
  }
}

// Why a click at `point` would not land in the window numbered `window` of process `pid`, given the on-screen
// windows front to back as CGWindowListCopyWindowInfo lists them; nil when it would. A window whose number is not
// known is refused.
func coveringWindowProblem(_ windows: [[String: Any]], at point: CGPoint, pid: pid_t, window: CGWindowID?) -> String? {
  let top = windows.first { info in
    guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
      (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
    else { return false }
    return rect.contains(point)
  }
  guard let top, (top[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == pid else {
    let owner = top?[kCGWindowOwnerName as String] as? String ?? "another window"
    return "\(owner) is on top at that point, so nothing was clicked."
  }
  guard let window else { return "The window's number could not be read, so it is unknown what is on top; nothing was clicked." }
  guard (top[kCGWindowNumber as String] as? Int).map({ CGWindowID($0) }) == window else {
    return "Another window of the app is on top at that point, so nothing was clicked."
  }
  return nil
}

// Brings an app forward and waits until it is. macOS may ignore activate() from an app in the background, as
// this helper is; Accessibility can still make the app frontmost.
func bringForward(_ app: NSRunningApplication, waiting seconds: TimeInterval = 0.5) -> Bool {
  let pid = app.processIdentifier
  let isFront = { onMain { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid } }
  _ = onMain { app.activate() }
  // Not through the effect gate: this also gives the focus back to the user's app, which must happen after a stop too.
  if !isFront() { AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue) }
  let deadline = Date().addingTimeInterval(seconds)
  while !isFront(), Date() < deadline { sleep(seconds: 0.05) }
  return isFront()
}

func postForegroundClick(at point: CGPoint, window: AXUIElement, app identity: AppIdentity, count: Int, style: ClickStyle = ClickStyle()) throws {
  let pid = identity.pid
  guard let app = try runningApplication(identity) else {
    throw HelperError(code: "app_not_found", message: "\(identity.name) is no longer running.")
  }
  let start = try beginEffect()
  AXUIElementPerformAction(window, kAXRaiseAction as CFString)
  guard bringForward(app, waiting: 1) else {
    throw HelperError(code: "action_failed", message: "The app did not come forward, so nothing was clicked.")
  }
  sleep(seconds: 0.15)
  let cursor = CGEvent(source: nil)?.location
  let source = CGEventSource(stateID: .hidSystemState)
  defer {
    if let cursor { CGWarpMouseCursorPosition(cursor) }
    CGAssociateMouseAndMouseCursorPosition(1)
    PointerActivity.noteOwnSystemInput()
  }
  guard let moved = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
    throw HelperError(code: "action_failed", message: "Could not create a mouse event.")
  }
  moved.flags = []
  let number = windowNumber(of: window)
  try requireOwnWindowOnTop(at: point, pid: pid, window: number)
  postSystemWide(moved, start)
  PointerActivity.noteOwnSystemInput()
  sleep(seconds: pointerEventGap)
  try pressThroughSystem(count: count, events: { click in
    let make = { (type: CGEventType) throws -> CGEvent in
      guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: style.button) else {
        throw HelperError(code: "action_failed", message: "Could not create a mouse event.")
      }
      event.flags = style.flags
      event.setIntegerValueField(.mouseEventClickState, value: Int64(click))
      return event
    }
    return (try make(style.types.down), try make(style.types.up))
  }, menuCheck: { try requireAllowedPoint(point, app: identity) }, windowCheck: {
    try requireOwnWindowOnTop(at: point, pid: pid, window: number)
  }, post: { event, press in
    postSystemWide(event, press)
    PointerActivity.noteOwnSystemInput()
    sleep(seconds: pointerEventGap)
  })
  sleep(seconds: 0.1)
}

// The presses of a click through the system. Both events of a press are made first; then, right before the button
// goes down, what lies under the point passes the menu check (`menuCheck`), the window asked for must be on top
// (`windowCheck`), and the effect gate checks the request's cancel and deadline, its permission covering that press
// alone: activating the app or an earlier press may have changed any of them. A button that went down always comes up.
func pressThroughSystem<Event>(count: Int, events: (Int) throws -> (down: Event, up: Event), menuCheck: () throws -> Void,
                               windowCheck: () throws -> Void, post: (Event, EffectStart) -> Void) throws {
  for click in 1...min(max(1, count), 3) {
    let press = try events(click)
    try menuCheck()
    try windowCheck()
    let start = try beginEffect()
    post(press.down, start)
    post(press.up, start)
  }
}
