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

// Through the public call, which addresses the process without the window server's live-input flag.
func postToProcess(_ event: CGEvent, pid: pid_t, _: EffectStart) {
  event.postToPid(pid)
}

// To the whole system, through the real cursor; only the foreground click does this.
func postSystemWide(_ event: CGEvent, _: EffectStart) {
  event.post(tap: .cghidEventTap)
}
