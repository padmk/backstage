// Several actions in one app as one request, so an agent that knows the next steps saves a round trip for each.
// The steps run in order and stop at the first that fails or may have worked, since later steps would act on a
// state nobody has seen. Nothing is retried. The effect of all of them is reported once, at the end.

import AppKit

let maxSteps = 20
// Gives the app a moment to take each step in before the next one arrives.
private let stepPauseSeconds = 0.15

func runActions(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  guard let steps = params["steps"] as? [JSON], !steps.isEmpty, steps.count <= maxSteps else {
    throw HelperError(code: "invalid_request", message: "steps must list 1 to \(maxSteps) actions.")
  }
  let frontBefore = onMain { NSWorkspace.shared.frontmostApplication }
  var done: [JSON] = []
  var failure: JSON?
  for (index, step) in steps.enumerated() {
    let method = try string(step, "tool")
    guard actionMethods.contains(method) else {
      throw HelperError(code: "invalid_request", message: "Step \(index + 1): \(method) is not an action.")
    }
    if index > 0 { sleep(seconds: stepPauseSeconds) }
    do {
      try currentConnection()?.throwIfCancelled()
      var arguments = step
      arguments["tool"] = nil
      arguments["app"] = params["app"]
      var outcome = try performAction(method, app: app, params: arguments, session: session)
      outcome["tool"] = method
      done.append(outcome)
    } catch let error as HelperError {
      if error.code == "interrupted" || error.code == "cancelled" { throw error }
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
  result["state"] = observeChange(app: app, session: session)
  _ = returnFocus(to: frontBefore, from: app.pid)
  return result
}
