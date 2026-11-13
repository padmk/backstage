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
  enum End { case exited, timedOut, interrupted, outputHeldOpen }
  let end: End
  let status: Int32
  let output: String
  let errors: String
  let timeout: TimeInterval
}

// Runs a child of the helper, which macOS treats as acting for the helper, and kills it when it overruns.
func runProcess(_ path: String, _ arguments: [String], input: Data? = nil, target: String, timeout: TimeInterval) throws -> (status: Int32, output: String, errors: String) {
  let child = try runChild(path, arguments, input: input, target: target, timeout: timeout)
  switch child.end {
  case .timedOut: throw HelperError(code: "timeout", message: "\(target) did not answer within \(Int(timeout)) seconds.")
  case .interrupted: throw HelperError(code: "interrupted", message: "The request was cancelled while \(target) was working, so it was stopped.")
  case .outputHeldOpen: throw outputHeldOpen(target)
  case .exited: return (child.status, child.output, child.errors)
  }
}

// Throws only when the child did not start; once it has, how it ended comes back with what it wrote so far.
func runChild(_ path: String, _ arguments: [String], input: Data? = nil, target: String, timeout: TimeInterval) throws -> ChildRun {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: path)
  process.arguments = arguments
  let output = Pipe()
  let errors = Pipe()
  process.standardOutput = output
  process.standardError = errors
  let inputPipe = input.map { _ in Pipe() }
  process.standardInput = inputPipe ?? FileHandle.nullDevice
  let finished = DispatchSemaphore(value: 0)
  process.terminationHandler = { _ in finished.signal() }
  // A request cancelled before this point starts nothing.
  let connection = currentConnection()
  try connection?.throwIfCancelled()
  try process.run()
  // A cancelled request ends its child, so a long script or shortcut does not hold the connection. Only a child
  // that the cancel actually stopped counts as interrupted; one that finished first keeps its result.
  let interruption = ChildInterruption()
  let stopWatching = connection?.onCancel { interruption.interrupt(process) }
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
  if finished.wait(timeout: .now() + timeout) == .timedOut {
    process.terminate()
    _ = finished.wait(timeout: .now() + 1)
    end = .timedOut
  }
  if end == .exited, interruption.happened, process.terminationReason == .uncaughtSignal { end = .interrupted }
  // A process the child started can keep the output open after the child ends; what was read is then incomplete.
  let outputDeadline = DispatchTime.now() + 2
  let out = outputReader.data(by: outputDeadline)
  let err = errorReader.data(by: outputDeadline)
  if end == .exited, out == nil || err == nil { end = .outputHeldOpen }
  return ChildRun(end: end, status: process.isRunning ? -1 : process.terminationStatus,
                  output: out.map { String(decoding: $0, as: UTF8.self) } ?? "", errors: err.map { String(decoding: $0, as: UTF8.self) } ?? "",
                  timeout: timeout)
}

private func outputHeldOpen(_ target: String) -> HelperError {
  HelperError(code: "outcome_unknown", message: "\(target) finished, but a process it started kept its output open, so its result could not be read. Read the state before trying again.")
}

// Whether a cancel stopped the child: it ends the child only while it runs, and only then counts.
private final class ChildInterruption: Sendable {
  private let interrupted = Mutex(false)

  func interrupt(_ process: Process) {
    interrupted.withLock { interrupted in
      guard process.isRunning else { return }
      interrupted = true
      process.terminate()
    }
  }

  var happened: Bool { interrupted.withLock { $0 } }
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
