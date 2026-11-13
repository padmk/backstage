// Several actions in one app as one request, so an agent that knows the next steps saves a round trip for each.
// The steps run in order and stop at the first that fails or may have worked, since later steps would act on a
// state nobody has seen. Nothing is retried. The effect of all of them is reported once, at the end.

import AppKit
import HelperLink

// Gives the app a moment to take each step in before the next one arrives.
private let stepPauseSeconds = 0.15

func runActions(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  guard let steps = params["steps"] as? [JSON], !steps.isEmpty, steps.count <= maxSteps else {
    throw HelperError(code: "invalid_request", message: "steps must list 1 to \(maxSteps) actions.")
  }
  // Every step is named right before any runs, so a typo late in the list changes nothing.
  for (index, step) in steps.enumerated() {
    let method = try string(step, "tool")
    guard actionMethods.contains(method) else {
      throw HelperError(code: "invalid_request", message: "Step \(index + 1): \(method) is not an action.")
    }
  }
  let frontBefore = onMain { NSWorkspace.shared.frontmostApplication }
  let watch = ChangeWatch(app: app)
  // Also when a cancel ends the steps early.
  defer { _ = returnFocus(to: frontBefore, from: app.pid) }
  var done: [JSON] = []
  var failure: JSON?
  for (index, step) in steps.enumerated() {
    let method = try string(step, "tool")
    if index > 0 { sleep(seconds: stepPauseSeconds) }
    do {
      try currentConnection()?.throwIfStopped()
      // The request was checked before the first step; the user may remove the app from the list or start working in
      // it, the app may quit and the screen may lock while the steps run.
      if index > 0 {
        try ApprovalGate.require(app, session: session)
        try requireSameProcess(app)
        try requireScreenUnlocked("run_actions", params: params, app: app, session: session)
        try requireUserNotWorking(in: app)
      }
      var arguments = step
      arguments["tool"] = nil
      arguments["app"] = params["app"]
      var outcome = try performAction(method, app: app, params: arguments, session: session)
      outcome["tool"] = method
      // A press the app answered with an error may have worked or not, so later steps would act on an unknown state.
      if let appError = outcome[appErrorKey] as? String {
        failure = ["step": index + 1, "tool": method, "code": "outcome_unknown", "message": appError]
        break
      }
      done.append(outcome)
    } catch let error as HelperError {
      // A cancel or the deadline ends the steps, whatever error it surfaced as.
      let stop = currentConnection()?.stopCause
      if stop != nil || error.code == "interrupted" || error.code == "cancelled" {
        // Steps that already ran may have changed something, so the stop must not read as nothing done.
        guard done.isEmpty else {
          let why = stop?.code == "expired" ? "Out of time" : "Cancelled"
          throw HelperError(code: "outcome_unknown", message: "\(why) after \(done.count) of \(steps.count) steps had run. Read the state before trying again.")
        }
        throw error
      }
      failure = ["step": index + 1, "tool": method, "code": error.code, "message": error.message]
      break
    }
  }
  _ = returnFocus(to: frontBefore, from: app.pid)
  var result: JSON = ["completed": done.count, "steps": done]
  if let failure {
    result["failed"] = failure
    result["note"] = "Steps after the failed one did not run. Read the state before going on."
  }
  result["state"] = observeChange(app: app, session: session, watch: watch)
  return result
}
