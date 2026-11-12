// Runs an app's scripting dictionary through JavaScript for Automation in an `osascript` child, so macOS
// asks for Automation on behalf of this app. The script text is fixed in the catalog; the arguments travel as
// one JSON value on the child's standard input, so no input can change what a script does, and none shows in the
// list of processes.

import Foundation

private let osascript = "/usr/bin/osascript"
private let defaultScriptSeconds: TimeInterval = 30

// The body sees the arguments as `args` and returns a value that becomes the result. It reports a known
// problem by throwing an Error whose message starts with an error code, such as "not_found: ...".
func runScript(_ body: String, arguments: JSON = [:], target: String, timeout: TimeInterval = defaultScriptSeconds) throws -> Any {
  let source = """
    ObjC.import('Foundation');
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
  let finished = try runProcess(osascript, ["-l", "JavaScript", "-e", source], input: input, target: target, timeout: timeout)
  guard finished.status == 0 else {
    throw scriptFailure(finished.errors, target: target)
  }
  let text = finished.output.trimmingCharacters(in: .whitespacesAndNewlines)
  guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
    throw HelperError(code: "action_failed", message: "\(target) gave an answer that could not be read.")
  }
  return value
}

// For the few commands JavaScript for Automation cannot address reliably. The script's `on main(argv)` receives the
// arguments as a list of strings, read from standard input as for JavaScript, and its result comes back as text.
func runAppleScript(_ source: String, arguments: [String], target: String, timeout: TimeInterval = defaultScriptSeconds) throws -> String {
  let reader = """
    use framework "Foundation"
    use scripting additions
    on run
      set input to current application's NSFileHandle's fileHandleWithStandardInput()'s readDataToEndOfFile()
      return main((current application's NSJSONSerialization's JSONObjectWithData:input options:0 |error|:(missing value)) as list)
    end run
    """
  let input = try JSONSerialization.data(withJSONObject: arguments)
  let finished = try runProcess(osascript, ["-e", reader + "\n" + source], input: input, target: target, timeout: timeout)
  guard finished.status == 0 else { throw scriptFailure(finished.errors, target: target) }
  return finished.output.trimmingCharacters(in: .whitespacesAndNewlines)
}

// Runs a child of the helper, which macOS treats as acting for the helper, and kills it when it overruns.
func runProcess(_ path: String, _ arguments: [String], input: Data? = nil, target: String, timeout: TimeInterval) throws -> (status: Int32, output: String, errors: String) {
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
  let stopped = NSLock()
  var interrupted = false
  let stopWatching = connection?.onCancel {
    stopped.withLock {
      guard process.isRunning else { return }
      interrupted = true
      process.terminate()
    }
  }
  defer { stopWatching?() }
  // Written while the child runs, as a large input would fill the pipe; a child that ends first only fails the write.
  if let input, let inputPipe {
    _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    DispatchQueue.global().async {
      try? inputPipe.fileHandleForWriting.write(contentsOf: input)
      try? inputPipe.fileHandleForWriting.close()
    }
  }

  // Read while it runs, because a large result would fill the pipe and stall the child.
  var outputData = Data()
  var errorData = Data()
  let readers = DispatchGroup()
  for (pipe, isOutput) in [(output, true), (errors, false)] {
    readers.enter()
    DispatchQueue.global().async {
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      if isOutput { outputData = data } else { errorData = data }
      readers.leave()
    }
  }
  if finished.wait(timeout: .now() + timeout) == .timedOut {
    process.terminate()
    _ = finished.wait(timeout: .now() + 1)
    throw HelperError(code: "timeout", message: "\(target) did not answer within \(Int(timeout)) seconds.")
  }
  _ = readers.wait(timeout: .now() + 2)
  if stopped.withLock({ interrupted }), process.terminationReason == .uncaughtSignal {
    throw HelperError(code: "interrupted", message: "The request was cancelled while \(target) was working, so it was stopped.")
  }
  return (process.terminationStatus, String(data: outputData, encoding: .utf8) ?? "", String(data: errorData, encoding: .utf8) ?? "")
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
