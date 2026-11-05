// The user working in the app an agent is about to act in, where the agent's input would mix with theirs.

import AppKit

// Input this recent in the front app counts as the user working there.
private let userActiveSeconds = 2.0

func requireUserNotWorking(in app: AppIdentity) throws {
  guard onMain({ NSWorkspace.shared.frontmostApplication?.processIdentifier }) == app.pid else { return }
  let anyInput = CGEventType(rawValue: ~0)!
  let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
  guard idle >= userActiveSeconds else {
    throw HelperError(code: "user_active", message: "The user is working in \(app.name) right now, so nothing was done there. Try again in a few seconds, or ask the user.")
  }
}
