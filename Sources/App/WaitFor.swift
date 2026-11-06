// Waiting until something shows in a window, or stops showing: a dialog, a result, a progress bar going away.
// Each look reads the window under the app's lock and lets go of it between looks, so other agents working in the
// same app are not held up while one waits.

import Foundation

private let maxWaitSeconds = 30.0
private let pollSeconds = 0.25

func waitFor(app: AppIdentity, params: JSON, connection: Connection) throws -> JSON {
  let text = try string(params, "text")
  guard !text.isEmpty else { throw HelperError(code: "invalid_request", message: "text is empty.") }
  let role = params["role"] as? String
  let gone = params["gone"] as? Bool == true
  let timeout = min(max((params["timeout"] as? NSNumber)?.doubleValue ?? 10, 0.5), maxWaitSeconds)
  let session = connection.session
  var read = params
  for key in ["text", "role", "gone", "timeout"] { read[key] = nil }
  let started = Date()
  while true {
    try connection.throwIfCancelled()
    let (line, complete): (String?, Bool) = try AppLocks.with(app.bundleId, connection: connection) {
      try ApprovalGate.require(app, session: session)
      try requireSameProcess(app)
      try requireScreenUnlocked("get_window_state", params: read, app: app, session: session)
      let tree = try readTree(app: app, params: read, session: session, shownToAgent: false).tree
      let match = tree.lines.first { line in
        line.localizedCaseInsensitiveContains(text) && (role.map { line.localizedCaseInsensitiveContains($0) } ?? true)
      }
      return (match, tree.partialReason == nil)
    }
    let waited = Int(Date().timeIntervalSince(started) * 1000)
    // A read cut short may have missed the text, so only a complete one shows it is gone.
    if line != nil ? !gone : (gone && complete) {
      var result: JSON = ["found": !gone, "waited_ms": waited]
      if let line { result["line"] = line.trimmingCharacters(in: .whitespaces) }
      return result
    }
    if Date().timeIntervalSince(started) >= timeout {
      var result: JSON = ["found": line != nil, "timed_out": true, "waited_ms": waited]
      if !complete { result["note"] = "The app answered only in part, so whether the text is there is not certain. Read a smaller area with root." }
      return result
    }
    sleep(seconds: pollSeconds)
  }
}
