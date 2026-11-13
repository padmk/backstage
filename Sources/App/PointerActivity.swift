// The user's pointer input as it happens, kept apart from the rules in Presence.swift that act on it: which app's
// window took each scroll, drag and click, and when Backstage itself last posted input to the whole system.

import AppKit

enum PointerActivity {
  // How long input counts as the user working in an app.
  static let recentSeconds = 2.0

  private static let lock = NSLock()
  private static var ownSystemInputAt = Date.distantPast
  // The apps whose windows took the user's scrolling, dragging or clicking, with when they last did.
  private static var inputTimes: [pid_t: Date] = [:]

  // Touched on the main thread only. The app the last press went to, which its drag goes on to wherever the pointer
  // moves; and the owners of the windows events went to, since a window keeps its owner.
  private static var lastPressPid: pid_t?
  private static var windowOwners: [Int: pid_t] = [:]
  private static let maxWindowOwners = 256
  private static var monitor: Any?

  // A window in the background takes scrolling, dragging and clicks without its app coming forward, so the app of the
  // window each went to is noted as it happens. Moving the pointer across a window on the way elsewhere is not
  // counted. Events Backstage posted carry its process id and are left out. Started once, on the main thread.
  static func start() {
    let ownPid = Int64(getpid())
    let types: NSEvent.EventTypeMask = [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown,
      .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
    monitor = NSEvent.addGlobalMonitorForEvents(matching: types) { event in
      guard let input = event.cgEvent, input.getIntegerValueField(.eventSourceUnixProcessID) != ownPid else { return }
      let isDrag = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type)
      let pid = isDrag ? lastPressPid : owner(ofWindow: event.windowNumber)
      if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { lastPressPid = pid }
      guard let pid else { return }
      let now = Date()
      lock.withLock {
        inputTimes = inputTimes.filter { now.timeIntervalSince($0.value) < recentSeconds }
        inputTimes[pid] = now
      }
    }
  }

  // Whether the user scrolled, dragged or clicked in one of the app's windows within the last two seconds.
  static func recentInput(in pid: pid_t) -> Bool {
    let time = lock.withLock { inputTimes[pid] }
    return time.map { Date().timeIntervalSince($0) < recentSeconds } ?? false
  }

  // When Backstage last posted input to the whole system (a click with foreground) or put the pointer back.
  static func noteOwnSystemInput() {
    lock.withLock { ownSystemInputAt = Date() }
  }

  static var secondsSinceOwnSystemInput: Double {
    lock.withLock { Date().timeIntervalSince(ownSystemInputAt) }
  }

  private static func owner(ofWindow number: Int) -> pid_t? {
    guard number > 0 else { return nil }
    if let known = windowOwners[number] { return known }
    guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [JSON])?.first,
      let pid = (info[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) else { return nil }
    if windowOwners.count >= maxWindowOwners { windowOwners.removeAll() }
    windowOwners[number] = pid
    return pid
  }
}
