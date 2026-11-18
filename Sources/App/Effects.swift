// The one gate every effect of a request passes: an Accessibility action or value, a key, pointer or scroll event,
// a save to a store, starting or quitting an app. Reads that prepare an effect can take long, as an app may not
// answer, so the request's cancel and deadline are checked here, after them and right before the effect; from the
// first effect on, a stop is reported as outcome_unknown, since what was done stays done.

import AppKit
import ApplicationServices

// Proof that the gate was passed: only `beginEffect` makes one, and the calls that post events take one.
struct EffectStart {
  fileprivate init() {}
}

// Without a running request, as in the app's own work and in tests, there is nothing to stop.
@discardableResult
func beginEffect(progress: String? = nil) throws -> EffectStart {
  try currentConnection()?.beginEffect(progress: progress)
  return EffectStart()
}

@discardableResult
func performAXAction(_ element: AXUIElement, _ action: String) throws -> AXError {
  try beginEffect()
  return AXUIElementPerformAction(element, action as CFString)
}

@discardableResult
func setAXAttribute(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) throws -> AXError {
  try beginEffect()
  return AXUIElementSetAttributeValue(element, name as CFString, value)
}

// The key, pointer and window server events of one effect, for the process a request was decided for. Each event goes to the pid only
// while the kernel shows the pid still runs that process, checked right before it, so input stops when the app quits
// midway and a process that takes the pid over is sent nothing more. The check and the post are two calls, so a pid
// that changes hands between them can still get that one event.
final class ProcessInput {
  let app: AppIdentity
  private var posted = false

  init(_ app: AppIdentity) { self.app = app }

  // Through the public call, as keys go.
  func postKey(_ event: CGEvent, _ start: EffectStart, progress: String? = nil) throws {
    try requireSameProcess(progress: progress)
    postToProcess(event, pid: app.pid, start)
    posted = true
  }

  // Through the private call when there is one, which lets a pointer event name its window.
  func postPointer(_ event: CGEvent, _ start: EffectStart) throws {
    try requireSameProcess(progress: nil)
    post(event, to: app.pid, start)
    posted = true
  }

  // A window server record, which `send` posts and reports as posted.
  func postRecord(_ start: EffectStart, _ send: () -> Bool) throws -> Bool {
    try requireSameProcess(progress: nil)
    posted = true
    return send()
  }

  // Before the first event nothing was done; after it, what went out stays, so the outcome is unknown.
  private func requireSameProcess(progress: String?) throws {
    guard posted else { return try App.requireSameProcess(app) }
    guard let expected = app.processStart, processStart(of: app.pid) == expected else {
      let done = progress ?? "the input had begun"
      throw HelperError(code: "outcome_unknown", message: "\(app.name) stopped (app_changed) after \(done). Read the state before trying again.")
    }
  }
}

// Through the public call, which addresses the process without the window server's live-input flag.
func postToProcess(_ event: CGEvent, pid: pid_t, _: EffectStart) {
  event.postToPid(pid)
}

// To the whole system, through the real cursor; only the foreground click does this.
func postSystemWide(_ event: CGEvent, _: EffectStart) {
  event.post(tap: .cghidEventTap)
}
