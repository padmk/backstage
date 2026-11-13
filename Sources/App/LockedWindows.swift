// Windows while the screen is locked, when the user has turned it on in the Backstage window. macOS keeps windows
// out of the accessibility tree and ScreenCaptureKit then, but the window server still lists them, a private
// SkyLight call still captures them, and pointer and key events posted to the app still reach them. So an agent
// can work from screenshots and coordinates, without elements and without any action being verified. Nothing
// here unlocks the Mac or wakes the displays.

import AppKit

private typealias MainConnection = @convention(c) () -> Int32
private typealias CaptureWindowList = @convention(c) (Int32, UnsafeMutablePointer<CGWindowID>, Int32, UInt32) -> Unmanaged<CFArray>?

private let mainConnection = lookUp("SLSMainConnectionID", as: MainConnection.self, in: skyLight)
private let captureWindowList = lookUp("SLSHWCaptureWindowList", as: CaptureWindowList.self, in: skyLight)
var lockedCaptureAvailable: Bool { mainConnection != nil && captureWindowList != nil }

// Only the window itself, at its full resolution.
private let captureOptions: UInt32 = 0x800 | 0x200

struct LockedWindow {
  let number: CGWindowID
  let title: String
  let bounds: CGRect
}

// The app's ordinary windows that were on screen when the screen locked, front to back.
func lockedWindows(pid: pid_t) -> [LockedWindow] {
  let all = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
  return all.compactMap { info in
    guard info[kCGWindowOwnerPID as String] as? pid_t == pid, info[kCGWindowLayer as String] as? Int == 0,
      info[kCGWindowIsOnscreen as String] as? Bool == true,
      let number = info[kCGWindowNumber as String] as? CGWindowID,
      let box = info[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: box as CFDictionary),
      bounds.width > 1, bounds.height > 1
    else { return nil }
    return LockedWindow(number: number, title: info[kCGWindowName as String] as? String ?? "", bounds: bounds)
  }
}

// The requests that work on a locked screen when the user allows it: screenshots, and input by coordinates or
// to the focused element.
func worksOnLockedWindows(_ method: String, params: JSON) -> Bool {
  guard Preferences.worksInWindowsWhileLocked else { return false }
  switch method {
  case "screenshot", "press_key": return true
  case "click_at": return params["element"] == nil && params["foreground"] as? Bool != true
  case "type_text": return params["element"] == nil
  default: return false
  }
}

func lockedWindowRequest(_ method: String, app: AppIdentity, params: JSON) throws -> JSON {
  switch method {
  case "screenshot":
    return try captureLockedWindow(try lockedWindow(app: app, params: params), recognizeText: params["text"] as? Bool == true)
  case "click_at":
    let window = try lockedWindow(app: app, params: params)
    let style = try ClickStyle.parse(button: params["button"] as? String, modifiers: params["modifiers"] as? [String] ?? [])
    let x = try number(params, "x")
    let y = try number(params, "y")
    guard x >= 0, y >= 0, x <= window.bounds.width, y <= window.bounds.height else {
      throw HelperError(code: "out_of_window", message: "The point is outside the window (\(wholePoints(window.bounds.width))×\(wholePoints(window.bounds.height))).")
    }
    try makeKey(window, app: app)
    try postClick(at: CGPoint(x: window.bounds.minX + x, y: window.bounds.minY + y),
                  target: PointerTarget(window: window.number, origin: window.bounds.origin), pid: app.pid,
                  count: params["count"] as? Int ?? 1, style: style)
    return lockedReply(["delivery": "pointer_event", "window": window.title])
  case "press_key":
    let key = try KeyCombination.parse(try string(params, "key"))
    try requireAllowedKey(key, app: app)
    try postKey(key, pid: app.pid)
    return lockedReply(["delivery": "key_events"])
  case "type_text":
    let text = try nonEmptyString(params, "text")
    try requireTextForKeys(text)
    try postText(text, pid: app.pid)
    return lockedReply(["delivery": "key_events"])
  default:
    throw HelperError(code: "screen_locked", message: "\(method) does not work while the screen is locked.")
  }
}

private func lockedReply(_ reply: JSON) -> JSON {
  var reply = reply
  reply["verified"] = false
  reply["state"] = ["unknown": true, "reason": "The screen is locked, so the window cannot be read. Take a screenshot to see the effect."] as JSON
  return reply
}

// Chromium and Electron take input only in their key window, so a click makes its window key first, and later keys
// go to that window.
private func makeKey(_ window: LockedWindow, app: AppIdentity) throws {
  guard isChromiumApp(path: app.path) else { return }
  _ = makeKeyInApp(window: window.number, pid: app.pid, try beginEffect())
}

private func lockedWindow(app: AppIdentity, params: JSON) throws -> LockedWindow {
  let all = lockedWindows(pid: app.pid)
  let index = params["window"] as? Int ?? 0
  guard index >= 0, index < all.count else {
    throw HelperError(code: "window_not_found", message: all.isEmpty
      ? "\(app.name) had no window on screen when the screen locked."
      : "There is no window \(index); \(app.name) has \(all.count): \(all.enumerated().map { "\($0.offset):\"\(clamped($0.element.title))\"" }.joined(separator: " ")).")
  }
  return all[index]
}

// One image pixel per window point, as unlocked screenshots, so the coordinates work with click_at.
private func captureLockedWindow(_ window: LockedWindow, recognizeText: Bool) throws -> JSON {
  try requirePermission(.screenRecording, for: "A screenshot")
  guard let mainConnection, let captureWindowList else {
    throw HelperError(code: "action_failed", message: "This macOS cannot capture windows while the screen is locked.")
  }
  var number = window.number
  guard let captured = (captureWindowList(mainConnection(), &number, 1, captureOptions)?.takeRetainedValue() as? [CGImage])?.first else {
    throw HelperError(code: "action_failed", message: "The window could not be captured.")
  }
  let width = Int(window.bounds.width.rounded())
  let height = Int(window.bounds.height.rounded())
  guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    throw HelperError(code: "action_failed", message: "The image could not be scaled.")
  }
  context.interpolationQuality = .high
  context.draw(captured, in: CGRect(x: 0, y: 0, width: width, height: height))
  guard let image = context.makeImage(),
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    throw HelperError(code: "action_failed", message: "The image could not be encoded.")
  }
  let reply: JSON = ["png_base64": data.base64EncodedString(), "width": width, "height": height, "title": window.title,
                      "note": "The screen is locked: this is the window as the window server last drew it."]
  return recognizeText ? addingRecognizedText(to: reply, image: image) : reply
}
