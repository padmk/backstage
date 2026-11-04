// Runs an app's scripting dictionary through JavaScript for Automation in an `osascript` child, so macOS
// asks for Automation on behalf of this app. The script text is fixed in the catalog; the arguments travel as
// one JSON value after `--`, so no input can change what a script does.

import Foundation

private let osascript = "/usr/bin/osascript"
private let defaultScriptSeconds: TimeInterval = 30

// The body sees the arguments as `args` and returns a value that becomes the result. It reports a known
// problem by throwing an Error whose message starts with an error code, such as "not_found: ...".
func runScript(_ body: String, arguments: JSON = [:], target: String, timeout: TimeInterval = defaultScriptSeconds) throws -> Any {
  let source = """
    function run(argv) {
      const args = JSON.parse(argv[0]);
      const value = (function () {
    \(body)
      })();
      return JSON.stringify(value === undefined ? null : value);
    }
    """
  let input = String(data: try JSONSerialization.data(withJSONObject: arguments), encoding: .utf8) ?? "{}"
  let finished = try runProcess(osascript, ["-l", "JavaScript", "-e", source, "--", input], target: target, timeout: timeout)
  guard finished.status == 0 else {
    throw scriptFailure(finished.errors, target: target)
  }
  let text = finished.output.trimmingCharacters(in: .whitespacesAndNewlines)
  guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
    throw HelperError(code: "action_failed", message: "\(target) gave an answer that could not be read.")
  }
  return value
}

// Runs a child of the helper, which macOS treats as acting for the helper, and kills it when it overruns.
func runProcess(_ path: String, _ arguments: [String], target: String, timeout: TimeInterval) throws -> (status: Int32, output: String, errors: String) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: path)
  process.arguments = arguments
  let output = Pipe()
  let errors = Pipe()
  process.standardOutput = output
  process.standardError = errors
  process.standardInput = FileHandle.nullDevice
  let finished = DispatchSemaphore(value: 0)
  process.terminationHandler = { _ in finished.signal() }
  try process.run()

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
