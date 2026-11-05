// What agents see of an app over time: reads that report only what changed since the last one, actions followed by
// a report of their effect once the app has settled, and one request at a time per app across all sessions.

import AppKit
import ApplicationServices

// An app that has not changed within this time after an action is taken to have ignored it.
private let firstChangeSeconds = 1.0
// After a change, the app counts as settled once it has stayed the same for this long.
private let quietSeconds = 0.3
// The longest an action waits for the app to settle, for example while it shows a spinner.
private let settleLimitSeconds = 5.0
private let pollSeconds = 0.1
// Each read while waiting gets at most this long, so a slow app cannot hold the reply for the full read limit.
private let pollReadSeconds = 2.0
// The last reads a session keeps for change reports, across the apps it works in.
private let maxRememberedReads = 32

// Two agents acting in the same app would interleave their clicks and keys and misread each other's effects, so
// each request that reads or acts in an app holds that app's lock until its report is done. Other apps go on.
enum AppLocks {
  private static let guardLock = NSLock()
  private static var locks: [pid_t: NSLock] = [:]

  static func with<T>(_ pid: pid_t, connection: Connection, _ body: () throws -> T) throws -> T {
    let lock = guardLock.withLock { () -> NSLock in
      if let known = locks[pid] { return known }
      let made = NSLock()
      locks[pid] = made
      return made
    }
    // Waiting for another agent stays cancellable.
    while !lock.lock(before: Date().addingTimeInterval(0.1)) { try connection.throwIfCancelled() }
    defer { lock.unlock() }
    return try body()
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
  let read = try readTree(app: app, params: params, session: session, shownToAgent: true)
  let previous = session.lock.withLock { session.lastReads[app.pid] }
  let isPartial = read.tree.partialReason != nil
  remember(LastRead(request: params, root: read.root, lines: read.tree.lines, isPartial: isPartial), pid: app.pid, session: session)

  if params["full"] as? Bool != true, !isPartial, let previous, !previous.isPartial, previous.covers(params, root: read.root) {
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

// A busy indicator that was not there before the action means the app is still working on it.
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
  var result: JSON
  do {
    result = try action()
  } catch {
    _ = returnFocus(to: frontBefore, from: app.pid)
    throw error
  }
  defer { _ = returnFocus(to: frontBefore, from: app.pid) }
  if returnFocus(to: frontBefore, from: app.pid) { result["focus_returned"] = true }
  result["state"] = observeChange(app: app, session: session)
  return result
}

func observeChange(app: AppIdentity, session: ApprovalSession) -> JSON {
  guard let last = session.lock.withLock({ session.lastReads[app.pid] }) else {
    return ["unknown": true, "reason": "Nothing was read before this action, so changes cannot be reported."] as JSON
  }
  if last.isPartial {
    return ["unknown": true, "reason": "The last read was partial, so changes cannot be reported. Read a smaller area with root."] as JSON
  }
  let started = Date()
  let before = Set(last.lines)
  var after = last.lines
  var lastChange: Date?
  var settled = true
  while true {
    sleep(seconds: pollSeconds)
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
      return ["unknown": true, "reason": "The app answered only in part: \(partial)"] as JSON
    }
    let now = Date()
    if read.tree.lines != after {
      after = read.tree.lines
      lastChange = now
    }
    let waited = now.timeIntervalSince(started)
    guard let changedAt = lastChange else {
      if waited >= firstChangeSeconds { break }
      continue
    }
    if now.timeIntervalSince(changedAt) >= quietSeconds, !showsNewBusyIndicator(after, comparedTo: before) { break }
    if waited >= settleLimitSeconds {
      settled = false
      break
    }
  }
  var report = changeReport(before: last.lines, after: after)
  if !settled {
    report["settled"] = false
    report["note"] = "The app was still changing or showed a busy indicator after \(Int(settleLimitSeconds)) s. Read the state again before relying on it."
  }
  remember(LastRead(request: last.request, root: last.root, lines: after, isPartial: false), pid: app.pid, session: session)
  return report
}
