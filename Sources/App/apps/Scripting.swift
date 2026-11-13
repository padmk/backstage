// Runs an app's scripting dictionary through JavaScript for Automation in an `osascript` child, so macOS
// asks for Automation on behalf of this app. The script text is fixed in the catalog; the arguments travel as
// one JSON value on the child's standard input, so no input can change what a script does, and none shows in the
// list of processes.

import Foundation
import HelperLink
import Synchronization

private let osascript = "/usr/bin/osascript"
private let defaultScriptSeconds: TimeInterval = 30

// What a script writes to its standard error, alone on a line, when it may start to change something; JSON
// details may follow on the line. From then on a failure, whatever its kind, may leave the change made.
private let changeMarker = "\u{1}change_began\u{1}"

// The body sees the arguments as `args` and returns a value that becomes the result. It reports a known
// problem by throwing an Error whose message starts with an error code, such as "not_found: ...". Right before
// its first command that may change something, it calls `changeBegins(details)` with what identifies the change,
// such as a document id and a cell; every failure after that is reported as outcome_unknown with those details.
func runScript(_ body: String, arguments: JSON = [:], target: String, timeout: TimeInterval = defaultScriptSeconds) throws -> Any {
  let source = """
    ObjC.import('Foundation');
    function changeBegins(details) {
      console.log(\(jsonText(changeMarker)) + JSON.stringify(details === undefined ? {} : details));
    }
    function run() {
      const input = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
      const args = JSON.parse($.NSString.alloc.initWithDataEncoding(input, $.NSUTF8StringEncoding).js);
      const value = (function () {
    \(body)
      })();
      return JSON.stringify(value === undefined ? null : value);
    }
    """
  let input = try JSONSerialization.data(withJSONObject: arguments)
  let child = try runChild(osascript, ["-l", "JavaScript", "-e", source], input: input, target: target, timeout: timeout)
  return try reportingChange(child, target: target) {
    let text = child.output.trimmingCharacters(in: .whitespacesAndNewlines)
    // An answer that does not parse is reported as unreadable; the parser's reason names no fix.
    guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
      throw HelperError(code: "action_failed", message: "\(target) gave an answer that could not be read.")
    }
    return value
  }
}

// For the few commands JavaScript for Automation cannot address reliably. The script's `on main(argv)` receives the
// arguments as a list of strings, read from standard input as for JavaScript, and its result comes back as text.
// Right before its first command that may change something it calls `my changeBegins()`, and `changeDetails` then
// names the change in an outcome_unknown; they stay out of the script's text like every argument.
func runAppleScript(_ source: String, arguments: [String], target: String, timeout: TimeInterval = defaultScriptSeconds, changeDetails: JSON = [:]) throws -> String {
  let reader = """
    use framework "Foundation"
    use scripting additions
    on run
      set input to current application's NSFileHandle's fileHandleWithStandardInput()'s readDataToEndOfFile()
      return main((current application's NSJSONSerialization's JSONObjectWithData:input options:0 |error|:(missing value)) as list)
    end run
    on changeBegins()
      log (character id 1) & "change_began" & (character id 1)
    end changeBegins
    """
  let input = try JSONSerialization.data(withJSONObject: arguments)
  let child = try runChild(osascript, ["-e", reader + "\n" + source], input: input, target: target, timeout: timeout)
  return try reportingChange(child, target: target, details: changeDetails) { child.output.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// A string as a JavaScript literal.
private func jsonText(_ text: String) -> String {
  // An array of one string always serializes.
  let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
  return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
}

// The one place a script's end becomes its result or its error. Once the script said a change began, any failure
// (its own error, a timeout, a cancel, an answer that cannot be read) is outcome_unknown, naming what it changed;
// before that, failures keep their own codes, since nothing has changed yet.
private func reportingChange<Value>(_ child: ChildRun, target: String, details given: JSON = [:], result: () throws -> Value) throws -> Value {
  let lines = child.errors.split(separator: "\n", omittingEmptySubsequences: false)
  let marks = lines.filter { $0.hasPrefix(changeMarker) }
  let errors = lines.filter { !$0.hasPrefix(changeMarker) }.joined(separator: "\n")
  do {
    switch child.end {
    case .timedOut: throw HelperError(code: "timeout", message: "\(target) did not answer within \(Int(child.timeout)) seconds.")
    case .interrupted: throw HelperError(code: "interrupted", message: "The request was cancelled while \(target) was working, so it was stopped.")
    case .outputHeldOpen: throw outputHeldOpen(target)
    case .outOfTime: throw outOfTime(target)
    case .unstoppable: throw unstoppable(target, pid: child.pid)
    case .exited:
      guard child.status == 0 else { throw scriptFailure(errors, target: target) }
      return try result()
    }
  } catch let error as HelperError {
    guard let mark = marks.last, error.code != "outcome_unknown" else { throw error }
    var details = mark.dropFirst(changeMarker.count).trimmingCharacters(in: .whitespaces)
    // The details come from the catalog's own scripts as strings and numbers, which serialize.
    if details.isEmpty || details == "{}", !given.isEmpty, let data = try? JSONSerialization.data(withJSONObject: given, options: [.sortedKeys]) {
      details = String(decoding: data, as: UTF8.self)
    }
    let what = details.isEmpty || details == "{}" ? "" : " It concerned \(details)."
    throw HelperError(code: "outcome_unknown", message: "\(target) may have made the change: \(error.message)\(what) Read the state before trying again.")
  }
}

// How a child of the helper ended, with what it wrote.
struct ChildRun {
  // outputHeldOpen: it exited, but a process it started kept its output open, so what it wrote is not known.
  // outOfTime: it was stopped at the request's deadline, before its own limit.
  // unstoppable: it was to be stopped, but it still ran after the last signal.
  enum End { case exited, timedOut, interrupted, outputHeldOpen, outOfTime, unstoppable }
  let end: End
  let status: Int32
  let output: String
  let errors: String
  let timeout: TimeInterval
  let pid: pid_t
}

// Runs a child of the helper, which macOS treats as acting for the helper, and kills it when it overruns.
func runProcess(_ path: String, _ arguments: [String], input: Data? = nil, target: String, timeout: TimeInterval) throws -> (status: Int32, output: String, errors: String) {
  let child = try runChild(path, arguments, input: input, target: target, timeout: timeout)
  switch child.end {
  case .timedOut: throw HelperError(code: "timeout", message: "\(target) did not answer within \(Int(timeout)) seconds.")
  case .interrupted: throw HelperError(code: "interrupted", message: "The request was cancelled while \(target) was working, so it was stopped.")
  case .outputHeldOpen: throw outputHeldOpen(target)
  case .outOfTime: throw outOfTime(target)
  case .unstoppable: throw unstoppable(target, pid: child.pid)
  case .exited: return (child.status, child.output, child.errors)
  }
}

// How long a child that was told to stop has to end before it is killed, and to be gone after that.
private let terminateGraceSeconds = 1.0
private let killGraceSeconds = 2.0

// Throws only when the child did not start; once it has, how it ended comes back with what it wrote so far. A child
// that overruns or is cancelled is stopped before this returns, so it never outlives the request and the app's lock
// that it ran under: see `stopChild`.
func runChild(_ path: String, _ arguments: [String], input: Data? = nil, target: String, timeout: TimeInterval) throws -> ChildRun {
  let output = Pipe()
  let errors = Pipe()
  let inputPipe = input.map { _ in Pipe() }
  let watch = ChildWatch()
  // A request cancelled or out of time before this point starts nothing. A child ends before the request's deadline,
  // leaving time for the reply.
  let connection = currentConnection()
  try connection?.throwIfStopped()
  let timeLeft = connection?.timeLeftForWork
  if let timeLeft, timeLeft <= 0 { throw expiredError }
  let limit = min(timeout, timeLeft ?? timeout)
  let pid = try spawnInOwnGroup(path, arguments, input: inputPipe, output: output, errors: errors, target: target)
  watchExit(of: pid, watch)
  // A cancelled request ends its child, so a long script or shortcut does not hold the connection.
  let stopWatching = connection?.onCancel { watch.noteCancel() }
  defer { stopWatching?() }
  // Written while the child runs, as a large input would fill the pipe; a child that ends first only fails the write.
  if let input, let inputPipe {
    _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    DispatchQueue.global().async {
      // A child that ended first fails the write; its exit status reports what happened.
      try? inputPipe.fileHandleForWriting.write(contentsOf: input)
      // A child that ended first fails the write; its exit status reports what happened.
      try? inputPipe.fileHandleForWriting.close()
    }
  }

  // Read while it runs, because a large result would fill the pipe and stall the child.
  let outputReader = PipeReader(output.fileHandleForReading)
  let errorReader = PipeReader(errors.fileHandleForReading)
  var end = ChildRun.End.exited
  switch watch.wait(until: .now() + limit) {
  case .exited:
    break
  case .cancelled:
    // Only a child the cancel actually stopped counts as interrupted; one that finished first keeps its result.
    if !stopChild(pid, watch: watch) {
      end = .unstoppable
    } else if watch.diedOfSignal {
      end = .interrupted
    }
  case .timedOut:
    // Cut short by the request's deadline rather than its own limit, the child may have done part of its work.
    end = stopChild(pid, watch: watch) ? (limit < timeout ? .outOfTime : .timedOut) : .unstoppable
  }
  // A process the child started can keep the output open after the child ends; what was read is then incomplete.
  let outputDeadline = DispatchTime.now() + 2
  let out = outputReader.data(by: outputDeadline)
  let err = errorReader.data(by: outputDeadline)
  if end == .exited, out == nil || err == nil { end = .outputHeldOpen }
  return ChildRun(end: end, status: watch.exitStatus ?? -1,
                  output: out.map { String(decoding: $0, as: UTF8.self) } ?? "", errors: err.map { String(decoding: $0, as: UTF8.self) } ?? "",
                  timeout: timeout, pid: pid)
}

// Starts the child as the leader of a new process group (POSIX_SPAWN_SETPGROUP), so `stopChild` reaches it and what
// it starts through the group, whatever Foundation's Process would do (it made a group on macOS 27 but not on the
// macOS 26 CI runners). Only its standard input, output and error are inherited; signals start at their defaults.
private func spawnInOwnGroup(_ path: String, _ arguments: [String], input: Pipe?, output: Pipe, errors: Pipe, target: String) throws -> pid_t {
  var actions: posix_spawn_file_actions_t?
  var attributes: posix_spawnattr_t?
  posix_spawn_file_actions_init(&actions)
  posix_spawnattr_init(&attributes)
  defer {
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attributes)
  }
  if let input {
    posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO)
  } else {
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
  }
  posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
  posix_spawn_file_actions_adddup2(&actions, errors.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
  var defaults = sigset_t()
  sigfillset(&defaults)
  var noMask = sigset_t()
  sigemptyset(&noMask)
  posix_spawnattr_setsigdefault(&attributes, &defaults)
  posix_spawnattr_setsigmask(&attributes, &noMask)
  posix_spawnattr_setpgroup(&attributes, 0)
  posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
  let argv = ([path] + arguments).map { strdup($0) } + [nil]
  defer { argv.forEach { free($0) } }
  var pid: pid_t = 0
  let result = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
  // The child holds its own copies; the helper keeps only its ends, so the readers see the end when the child's go.
  try? output.fileHandleForWriting.close() // Closing a pipe end the helper owns fails only if already closed.
  try? errors.fileHandleForWriting.close() // Closing a pipe end the helper owns fails only if already closed.
  try? input?.fileHandleForReading.close() // Closing a pipe end the helper owns fails only if already closed.
  guard result == 0 else {
    throw HelperError(code: "action_failed", message: "\(target) could not be started: \(String(cString: strerror(result))).")
  }
  return pid
}

// Reaps the child on a thread of its own and reports how it ended.
private func watchExit(of pid: pid_t, _ watch: ChildWatch) {
  Thread.detachNewThread {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1, errno == EINTR {}
    watch.noteExit(status: status)
  }
}

// Stops a child and what it started: SIGTERM to its process group, then SIGKILL to the group once the grace period
// passes, and SIGKILL to the group again after the child is gone, for processes it started that ignored SIGTERM.
// `spawnInOwnGroup` makes the child the leader of a process group of its own, so the group holds the child and every
// process it started that did not leave it. A process that
// left the group (setsid, a daemon) or one launchd starts for it (open, an app) is out of reach and is not
// stopped. Returns whether the child itself is confirmed gone.
private func stopChild(_ pid: pid_t, watch: ChildWatch) -> Bool {
  // The group is signalled only while the child has not been seen to exit: until then its pid, and with it the
  // group's id, cannot belong to another process. After the exit the id stays the group's while members remain.
  if !watch.hasExited { kill(-pid, SIGTERM) }
  if !watch.waitForExit(until: .now() + terminateGraceSeconds) {
    kill(-pid, SIGKILL)
    guard watch.waitForExit(until: .now() + killGraceSeconds) else {
      appLog.error("A child of the helper (pid \(pid, privacy: .public)) still ran after SIGKILL.")
      return false
    }
  }
  // ESRCH when nothing of the group is left, which is the usual case.
  kill(-pid, SIGKILL)
  return true
}

private func outOfTime(_ target: String) -> HelperError {
  HelperError(code: "outcome_unknown", message: "\(target) was still working when the request's time ran out, so it was stopped; it may have done part of its work. Read the state before trying again.")
}

private func outputHeldOpen(_ target: String) -> HelperError {
  HelperError(code: "outcome_unknown", message: "\(target) finished, but a process it started kept its output open, so its result could not be read. Read the state before trying again.")
}

private func unstoppable(_ target: String, pid: pid_t) -> HelperError {
  HelperError(code: "outcome_unknown", message: "\(target) had to be stopped but still runs (process \(pid)) after it was killed, so it may go on working. Tell the user; read the state before trying again.")
}

// What a running child's waiter hears of: the child's exit, and a cancel of the request it runs for.
private final class ChildWatch: Sendable {
  enum Event { case exited, cancelled, timedOut }
  private struct State {
    // The wait status, once the child is reaped.
    var status: Int32?
    var cancelled = false
    var exited: Bool { status != nil }
  }
  private let state = Mutex(State())
  private let changed = DispatchSemaphore(value: 0)

  func noteExit(status: Int32) {
    state.withLock { $0.status = status }
    changed.signal()
  }

  func noteCancel() {
    state.withLock { $0.cancelled = true }
    changed.signal()
  }

  var hasExited: Bool { state.withLock { $0.exited } }

  // The exit code of a child that exited, or the wait status's own encoding of the signal that ended it.
  var exitStatus: Int32? {
    state.withLock { state in state.status.map { $0 & 0x7f == 0 ? ($0 >> 8) & 0xff : $0 & 0x7f } }
  }

  var diedOfSignal: Bool { state.withLock { $0.status.map { $0 & 0x7f != 0 && $0 & 0x7f != 0x7f } ?? false } }

  // The first of an exit, a cancel and the deadline; an exit wins over a cancel that came with it.
  func wait(until deadline: DispatchTime) -> Event {
    while true {
      let now = state.withLock { $0 }
      if now.exited { return .exited }
      if now.cancelled { return .cancelled }
      if changed.wait(timeout: deadline) == .timedOut { return hasExited ? .exited : .timedOut }
    }
  }

  func waitForExit(until deadline: DispatchTime) -> Bool {
    while !hasExited {
      if changed.wait(timeout: deadline) == .timedOut { return hasExited }
    }
    return true
  }
}

private func scriptFailure(_ text: String, target: String) -> HelperError {
  let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
  if message.contains("(-1743)") {
    return HelperError(code: "access_denied", message: "macOS does not let Backstage control \(target). Allow it in System Settings > Privacy & Security > Automation > Backstage, then try again.")
  }
  if message.contains("(-1712)") {
    return HelperError(code: "timeout", message: "\(target) did not answer in time.")
  }
  if message.contains("(-1728)") || message.contains("(-1719)") {
    return HelperError(code: "not_found", message: "\(target) has no such item.")
  }
  // A known problem the script reported itself: "Error: code: text (-2700)".
  if let match = message.range(of: #"Error: ([a-z_]+): (.*) \(-2700\)"#, options: .regularExpression) {
    let reported = String(message[match]).dropFirst("Error: ".count).dropLast(" (-2700)".count)
    if let colon = reported.firstIndex(of: ":") {
      return HelperError(code: String(reported[..<colon]), message: String(reported[reported.index(colon, offsetBy: 2)...]))
    }
  }
  return HelperError(code: "action_failed", message: "\(target) refused the script: \(message.prefix(500))")
}

func dictionary(_ value: Any, from target: String) throws -> JSON {
  guard let object = value as? JSON else { throw HelperError(code: "action_failed", message: "\(target) gave an unexpected answer.") }
  return object
}
