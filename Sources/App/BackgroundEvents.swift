// The private window server calls that deliver pointer input to an app without bringing it to the front. Each is
// looked up at run time, so a macOS release without one falls back to the public API instead of crashing.

import AppKit
import ApplicationServices

private let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

private func lookUp<Function>(_ name: String, as type: Function.Type, in library: UnsafeMutableRawPointer?) -> Function? {
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
