// What agents see of an app over time: reads that report only what changed since the last one, actions followed by
// a report of their effect once the app has settled, and one request at a time per app across all sessions.

import AppKit
import ApplicationServices

// The longest an action waits for the app to settle, for example while it shows a spinner.
private let settleLimitSeconds = 5.0
// Each read while waiting gets at most this long, so a slow app cannot hold the reply for the full read limit.
private let pollReadSeconds = 2.0

// An app that has not changed within this time after an action is taken to have ignored it.
private let firstChangeSeconds = 1.0

// For an app that reports its changes through Accessibility notifications, reads follow them: a read once they
// pause, and a last one to confirm. An action can take effect later than the app's first answer, so the wait for a
// first change stays firstChangeSeconds.
private let noticePauseSeconds = 0.05
// While notifications keep coming, a read at least this often, so a busy app is still compared.
private let readEverySeconds = 0.25
// After a change, the app counts as settled when a read this much later shows the same.
private let confirmSeconds = 0.1
// Before a first change, a read at least this often, also when the app reports nothing.
private let silentSeconds = 0.25

// For an app that has never sent one, and when notifications cannot be watched, reads on a fixed beat instead.
private let pollSeconds = 0.1
private let quietSeconds = 0.3
// The last reads a session keeps for change reports, across the apps it works in.
private let maxRememberedReads = 32

// Two agents acting in the same app would interleave their clicks and keys and misread each other's effects, so
// each request that reads or acts in an app holds that app's lock until its report is done. Other apps go on. The
// lock is the bundle id's, so an operation that starts a closed app holds the same lock as window work in it.
enum AppLocks {
  private static let guardLock = NSLock()
  private static var locks: [String: NSLock] = [:]

  static func with<T>(_ bundleId: String, connection: Connection, _ body: () throws -> T) throws -> T {
    let lock = guardLock.withLock { () -> NSLock in
      if let known = locks[bundleId] { return known }
      let made = NSLock()
      locks[bundleId] = made
      return made
    }
    // Waiting for another agent stays cancellable.
    while !lock.lock(before: Date().addingTimeInterval(0.1)) { try connection.throwIfCancelled() }
    defer { lock.unlock() }
    return try body()
  }
}

private let watchedNotifications = [
  kAXValueChangedNotification, kAXUIElementDestroyedNotification, kAXCreatedNotification, kAXTitleChangedNotification,
  kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
  kAXWindowCreatedNotification, kAXSheetCreatedNotification, kAXLayoutChangedNotification, kAXResizedNotification,
  kAXSelectedChildrenChangedNotification, kAXSelectedRowsChangedNotification, kAXSelectedTextChangedNotification,
  kAXRowCountChangedNotification, kAXMenuOpenedNotification, kAXMenuClosedNotification,
]

// The Accessibility notifications an app sends while an action takes effect, delivered on the thread that made the
// watch, in a run loop mode of its own, so nothing else runs while it waits.
final class ChangeWatch {
  private static let lock = NSLock()
  // Apps seen sending a notification, whose silence therefore means nothing changed.
  private static var notifying: Set<String> = []

  let bundleId: String
  private let observer: AXObserver
  private let application: AXUIElement
  private let runLoop = CFRunLoopGetCurrent()!
  private let mode = CFRunLoopMode("backstage.change-watch" as CFString)
  private(set) var count = 0
  private(set) var lastAt = Date.distantPast

  init?(app: AppIdentity) {
    var made: AXObserver?
    let callback: AXObserverCallback = { _, _, _, context in
      guard let context else { return }
      Unmanaged<ChangeWatch>.fromOpaque(context).takeUnretainedValue().noticed()
    }
    guard AXObserverCreate(app.pid, callback, &made) == .success, let made else { return nil }
    bundleId = app.bundleId
    observer = made
    application = AXUIElementCreateApplication(app.pid)
    let context = Unmanaged.passUnretained(self).toOpaque()
    let added = watchedNotifications.filter { AXObserverAddNotification(observer, application, $0 as CFString, context) == .success }
    guard !added.isEmpty else { return nil }
    CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), mode)
  }

  deinit {
    for name in watchedNotifications { AXObserverRemoveNotification(observer, application, name as CFString) }
    CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), mode)
  }

  private func noticed() {
    if count == 0 { _ = Self.lock.withLock { Self.notifying.insert(bundleId) } }
    count += 1
    lastAt = Date()
  }

  // Whether the app's notifications can be relied on: it sent one now or before.
  var appNotifies: Bool { count > 0 || Self.lock.withLock { Self.notifying.contains(bundleId) } }

  // Waits until `deadline`, or less when a notification arrives.
  func wait(until deadline: Date) {
    let seconds = deadline.timeIntervalSinceNow
    if seconds > 0 { _ = CFRunLoopRunInMode(mode, seconds, true) }
  }
}

func remember(_ read: LastRead, pid: pid_t, session: ApprovalSession) {
  session.lock.withLock {
    if session.lastReads.count >= maxRememberedReads, session.lastReads[pid] == nil { session.lastReads.removeAll() }
    session.lastReads[pid] = read
  }
}

// A read of the place last read in this session answers with what changed, unless the agent asks for everything.
// The full tree comes back on a first read, after a partial one, and when the changes would be longer than it.
func windowState(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  var reply = try treeState(app: app, params: params, session: session)
  // A screenshot of the same window right after the tree, for what the tree cannot show. Without Screen Recording
  // the tree still comes back.
  if params["screenshot"] as? Bool == true, params["menu_bar"] as? Bool != true, params["menu_extras"] as? Bool != true {
    do {
      // The window the tree came from, also when it was a subtree.
      let root = try (params["root"] as? Int).map { try session.table.element($0, pid: app.pid) }
      let window = try root.flatMap { attribute($0, kAXWindowAttribute).map { $0 as! AXUIElement } }
        ?? selectWindow(try applicationElement(app), params: params)
      reply.merge(try captureWindow(pid: app.pid, window: window)) { current, _ in current }
    } catch let error as HelperError {
      reply["screenshot_error"] = "\(error.code): \(error.message)"
    }
  }
  return reply
}

private func treeState(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  let read = try readTree(app: app, params: params, session: session, shownToAgent: true)
  let previous = session.lock.withLock { session.lastReads[app.pid] }
  let isPartial = read.tree.partialReason != nil
  remember(LastRead(request: params, root: read.root, lines: read.tree.lines, isPartial: isPartial), pid: app.pid, session: session)

  if params["full"] as? Bool != true, !isPartial, let previous, !previous.isPartial, !previous.reportedInPart,
     previous.covers(params, root: read.root) {
    let before = Set(previous.lines)
    let after = Set(read.tree.lines)
    let added = read.tree.lines.filter { !before.contains($0) }
    let removed = previous.lines.filter { !after.contains($0) }
    if added.isEmpty, removed.isEmpty {
      return ["tree": "\(read.header)\nNo change since your last read of this window. Pass full: true to see all of it."] as JSON
    }
    if added.count + removed.count < read.tree.lines.count {
      let changes = added.map { "+ \($0)" } + removed.map { "- \($0)" }
      let text = [read.header, "Changes since your last read of this window (+ new or changed, - gone); pass full: true to see all of it:"] + changes
      return ["tree": text.joined(separator: "\n")] as JSON
    }
  }
  let knowledge = knowledgeLines(forBundleId: app.bundleId)
  var text = ([read.header] + knowledge + read.tree.lines).joined(separator: "\n")
  if let reason = read.tree.partialReason { text += "\n[Partial: \(reason)]" }
  return ["tree": text] as JSON
}

// A busy indicator that was not there before the action means the app is still working on it. Both sides are the
// lines without their numbers, so one that only got a new number is not new.
private func showsNewBusyIndicator(_ lines: [String], comparedTo before: Set<String>) -> Bool {
  lines.contains { line in
    guard !before.contains(line) else { return false }
    return line.contains(" BusyIndicator") || (line.contains(" ProgressIndicator") && !line.contains(" value=\""))
  }
}

// Runs an action, then reports what changed in the app's last read, so the agent sees the effect and no
// action claims a success it did not observe. After the first change it waits until the app stays the same
// for a moment, so a spinner or a half-drawn view is not reported as the result.
func acting(app: AppIdentity, session: ApprovalSession, _ action: () throws -> JSON) throws -> JSON {
  let frontBefore = onMain { NSWorkspace.shared.frontmostApplication }
  let watch = ChangeWatch(app: app)
  var result: JSON
  do {
    result = try action()
  } catch {
    _ = returnFocus(to: frontBefore, from: app.pid)
    throw error
  }
  defer { _ = returnFocus(to: frontBefore, from: app.pid) }
  if returnFocus(to: frontBefore, from: app.pid) { result["focus_returned"] = true }
  let state = observeChange(app: app, session: session, watch: watch)
  if let appError = result[appErrorKey] as? String, state["changed"] as? Bool == false {
    throw HelperError(code: "action_failed", message: "\(appError) Nothing changed.")
  }
  result["state"] = state
  return result
}

// `watch` was made before the action, so it holds what the app reported while the action ran.
func observeChange(app: AppIdentity, session: ApprovalSession, watch: ChangeWatch?) -> JSON {
  guard let last = session.lock.withLock({ session.lastReads[app.pid] }) else {
    return ["unknown": true, "reason": "Nothing was read before this action, so changes cannot be reported."] as JSON
  }
  if last.isPartial {
    return ["unknown": true, "reason": "The last read was partial, so changes cannot be reported. Read a smaller area with root."] as JSON
  }
  let started = Date()
  // The reads below number new elements the agent never sees. Those numbers the reported read does not hold are
  // given up at the end, so they do not push out numbers the agent holds.
  let mintedFrom = session.table.nextFreeNumber
  var shownNumbers = Set<Int>()
  defer { session.table.forget(numbersFrom: mintedFrom, pid: app.pid, keeping: shownNumbers) }
  let before = Set(content(of: last.lines))
  var after = last.lines
  var afterContent = content(of: last.lines)
  var completeReads = 0
  var afterFingerprints: [Int: [String?]] = [:]
  var lastChange: Date?
  var settled = true
  var lastRead = started
  var noticesAtRead = 0
  while true {
    let followsNotices = watch?.appNotifies == true
    if let watch, followsNotices {
      // The next read: once notifications pause, or after a quiet stretch that confirms or ends the wait.
      while true {
        let pending = watch.count != noticesAtRead
        let next = pending
          ? min(watch.lastAt.addingTimeInterval(noticePauseSeconds), lastRead.addingTimeInterval(readEverySeconds))
          : lastRead.addingTimeInterval(lastChange == nil ? silentSeconds : confirmSeconds)
        let due = min(next, started.addingTimeInterval(settleLimitSeconds))
        if Date() >= due { break }
        watch.wait(until: due)
      }
    } else if let watch {
      // Still delivers notifications, which show whether this app sends them.
      let due = Date().addingTimeInterval(pollSeconds)
      while Date() < due { watch.wait(until: due) }
    } else {
      sleep(seconds: pollSeconds)
    }
    noticesAtRead = watch?.count ?? 0
    let elapsed = Date().timeIntervalSince(started)
    let read: WindowRead
    do {
      read = try readTree(app: app, params: last.request, session: session, shownToAgent: false,
                          seconds: min(pollReadSeconds, max(settleLimitSeconds - elapsed, pollSeconds)))
    } catch {
      let reason = (error as? HelperError)?.message ?? error.localizedDescription
      return ["unknown": true, "reason": "The earlier read cannot be repeated: \(reason)"] as JSON
    }
    if let partial = read.tree.partialReason {
      // A read cut short at the end of the wait leaves the last complete one to report.
      guard completeReads > 0 else { return ["unknown": true, "reason": "The app answered only in part: \(partial)"] as JSON }
      settled = false
      break
    }
    completeReads += 1
    let now = Date()
    lastRead = now
    // Some apps, such as System Settings, hand out new elements for unchanged ones on every read, which renumbers
    // them; only a change in what the lines say counts as the app still changing.
    let readContent = content(of: read.tree.lines)
    if read.tree.lines != after {
      after = read.tree.lines
      if readContent != afterContent { lastChange = now }
      afterContent = readContent
    }
    afterFingerprints = read.tree.fingerprints
    let waited = now.timeIntervalSince(started)
    guard let changedAt = lastChange else {
      if waited >= firstChangeSeconds { break }
      continue
    }
    let quiet = followsNotices ? confirmSeconds : quietSeconds
    if now.timeIntervalSince(changedAt) >= quiet, !showsNewBusyIndicator(afterContent, comparedTo: before) { break }
    if waited >= settleLimitSeconds {
      settled = false
      break
    }
  }
  shownNumbers = Set(after.compactMap(number(ofLine:)))
  var report = changeReport(before: last.lines, after: after)
  // Only the lines the report shows count as seen.
  let shown = Set(((report["added"] as? [String] ?? []) + (report["renumbered"] as? [String] ?? [])).compactMap(number(ofLine:)))
  session.table.acknowledge(afterFingerprints.filter { shown.contains($0.key) })
  if !settled {
    report["settled"] = false
    report["note"] = "The app was still changing or showed a busy indicator after \(Int(settleLimitSeconds)) s. Read the state again before relying on it."
  }
  remember(LastRead(request: last.request, root: last.root, lines: after, isPartial: false,
                    reportedInPart: last.reportedInPart || report["more_changes"] != nil || report["more_renumbered"] != nil), pid: app.pid, session: session)
  return report
}
