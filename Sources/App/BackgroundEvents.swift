// The private window server calls that deliver pointer input to an app without bringing it to the front. Each is
// looked up at run time, so a macOS release without one falls back to the public API instead of crashing.

import AppKit
import ApplicationServices

let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

func lookUp<Function>(_ name: String, as type: Function.Type, in library: UnsafeMutableRawPointer?) -> Function? {
  dlsym(library, name).map { unsafeBitCast($0, to: type) }
}

private typealias PostToPid = @convention(c) (pid_t, CGEvent) -> Void
private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
private typealias WindowOfElement = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

// Unlike the public call, it also tells the system the input is live.
private let postToPid = lookUp("SLEventPostToPid", as: PostToPid.self, in: skyLight)
let setEventWindowLocation: ((CGEvent, CGPoint) -> Void)? = lookUp("CGEventSetWindowLocation", as: SetWindowLocation.self, in: skyLight)
private let windowOfElement = lookUp("_AXUIElementGetWindow", as: WindowOfElement.self, in: dlopen(nil, RTLD_NOW))

let pointerEventGap = 0.03
// The event subtype background windows accept for clicks: with it, a click reaches a window that is not key.
let touchSubtype: Int64 = 3

func post(_ event: CGEvent, to pid: pid_t) {
  if let postToPid {
    postToPid(pid, event)
  } else {
    event.postToPid(pid)
  }
}

func windowNumber(of window: AXUIElement) -> CGWindowID? {
  var number = CGWindowID(0)
  guard let windowOfElement, windowOfElement(window, &number) == .success, number != 0 else { return nil }
  return number
}

// The target for a point inside `element`, or inside the window it belongs to.
func pointerTarget(for element: AXUIElement) -> PointerTarget {
  let window = stringAttribute(element, kAXRoleAttribute) == kAXWindowRole
    ? element
    : attribute(element, kAXWindowAttribute).map { $0 as! AXUIElement }
  guard let window, let box = frame(of: window) else { return PointerTarget(window: nil, origin: .zero) }
  return PointerTarget(window: windowNumber(of: window), origin: box.origin)
}

private typealias PostEventRecord = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32
private typealias ProcessForPid = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

private let postEventRecord = lookUp("SLPSPostEventRecordTo", as: PostEventRecord.self, in: skyLight)
private let processForPid = lookUp("GetProcessForPID", as: ProcessForPid.self, in: dlopen(nil, RTLD_NOW))
// The app drops a record that arrives while it still handles the one before.
private let keyRecordSettleSeconds = 0.12

private func windowRecord(kind: UInt8, window: CGWindowID) -> [UInt8] {
  var record = [UInt8](repeating: 0, count: 0xF8)
  record[0x04] = 0xF8
  record[0x08] = kind
  withUnsafeBytes(of: window.littleEndian) { bytes in
    for index in 0..<4 { record[0x3C + index] = bytes[index] }
  }
  return record
}

// Chromium takes pointer and key input only in its key window, and a window in an app the user is not using
// is not key. These records make `window` key inside the app, without activating the app or raising the
// window, so the user's front app keeps its focus. Returns whether every record was posted.
func makeKeyInApp(window: CGWindowID, pid: pid_t) -> Bool {
  guard let postEventRecord, let processForPid else { return false }
  var serial = [UInt8](repeating: 0, count: 8)
  guard processForPid(pid, &serial) == 0 else { return false }
  var focus = windowRecord(kind: 0x0D, window: window)
  focus[0x8A] = 0x01
  var posted = postEventRecord(serial, focus) == 0
  sleep(seconds: keyRecordSettleSeconds)
  for kind: UInt8 in [0x01, 0x02] {
    var makeKey = windowRecord(kind: kind, window: window)
    makeKey[0x3A] = 0x10
    for index in 0x20..<0x30 { makeKey[index] = 0xFF }
    posted = postEventRecord(serial, makeKey) == 0 && posted
  }
  sleep(seconds: keyRecordSettleSeconds)
  return posted
}

private var chromiumApps: [String: Bool] = [:]
private let chromiumAppsLock = NSLock()

// Chromium browsers keep their engine in a framework with helper apps inside it; Electron apps ship
// Electron Framework. AppKit apps are left alone: there the key records made the app report itself active.
func isChromiumApp(path: String?) -> Bool {
  guard let path else { return false }
  if let known = chromiumAppsLock.withLock({ chromiumApps[path] }) { return known }
  let frameworks = path + "/Contents/Frameworks"
  let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks)) ?? []
  let found = names.contains("Electron Framework.framework") || names.contains { name in
    name.hasSuffix(" Framework.framework")
      && FileManager.default.fileExists(atPath: "\(frameworks)/\(name)/Versions/Current/Helpers")
  }
  chromiumAppsLock.withLock { chromiumApps[path] = found }
  return found
}
