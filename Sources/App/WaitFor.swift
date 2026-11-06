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
    let line: String? = try AppLocks.with(app.bundleId, connection: connection) {
      try ApprovalGate.require(app, session: session)
      try requireSameProcess(app)
      try requireScreenUnlocked("get_window_state", params: read, app: app, session: session)
      return try readTree(app: app, params: read, session: session, shownToAgent: false).tree.lines.first { line in
        line.localizedCaseInsensitiveContains(text) && (role.map { line.localizedCaseInsensitiveContains($0) } ?? true)
      }
    }
    let waited = Int(Date().timeIntervalSince(started) * 1000)
    if (line != nil) != gone {
      var result: JSON = ["found": !gone, "waited_ms": waited]
      if let line { result["line"] = line.trimmingCharacters(in: .whitespaces) }
      return result
    }
    if Date().timeIntervalSince(started) >= timeout {
      return ["found": gone, "timed_out": true, "waited_ms": waited] as JSON
    }
    sleep(seconds: pollSeconds)
  }
}
