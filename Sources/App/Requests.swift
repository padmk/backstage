// The request router. Every request that touches an app resolves it, passes the gate, and proves the process is
// still the one approved, because a pid can be reused while the user reads the window.

import AppKit
import HelperLink
import ApplicationServices

func handle(method: String, params: JSON, connection: Connection) throws -> Any {
  let session = connection.session
  switch method {
  case "hello":
    session.lock.withLock {
      session.clientName = params["client_name"] as? String
    }
    return ["version": Configuration.buildVersion, "build": ownBuildIdentity] as JSON

  case "status":
    return [
      "accessibility": AXIsProcessTrusted(), "screen_recording": CGPreflightScreenCaptureAccess(), "version": Configuration.buildVersion,
      // The same grants as the Permissions tab: those of the listed apps.
      "app_access": appGrants(forListed: Set(ApprovalStore.list().compactMap { $0["bundle_id"] }), everyApp: Preferences.allowsEveryApp)
        .map { ["name": $0.name, "state": grantState($0).rawValue] as JSON },
    ] as JSON

  case "request_permissions":
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let accessibility = AXIsProcessTrustedWithOptions(options)
    // Screen Recording is optional, so it is asked for only when the caller says so.
    let screen = CGPreflightScreenCaptureAccess() || (params["screen_recording"] as? Bool == true && CGRequestScreenCaptureAccess())
    return ["accessibility": accessibility, "screen_recording": screen] as JSON

  case "quit":
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      unlink(Configuration.socketPath)
      exit(0)
    }
    return [:] as JSON

  case "approvals_list":
    return ["approvals": ApprovalStore.list()] as JSON

  case "approvals_revoke":
    let bundleId = try string(params, "bundle_id")
    let revoked = try ApprovalStore.revoke(bundleId: bundleId)
    if revoked { writeDecisionLog(client: commandLineClient, bundleId: bundleId, decision: "removed") }
    return ["revoked": revoked] as JSON

  case "approvals_add":
    let query = try string(params, "app")
    let app = try (try? resolve(query)) ?? installedIdentity(try installedApp(query))
    try addToList(app, by: commandLineClient)
    return ["added": app.bundleId, "name": app.name] as JSON

  case "list_apps":
    // With app: that one app, running or only installed, without starting it.
    if let query = params["app"] as? String {
      let app = try (try? resolve(query)) ?? installedIdentity(try installedApp(query))
      return ["app": ["name": app.name, "bundle_id": app.bundleId, "running": app.pid != 0, "access": ApprovalGate.access(app).rawValue],
              "every_app": Preferences.allowsEveryApp] as JSON
    }
    return ["apps": visibleApps().map { running in
      var entry = describe(running)
      entry["access"] = ApprovalGate.access(identity(of: running)).rawValue
      return entry
    }, "every_app": Preferences.allowsEveryApp] as JSON

  case "launch_app":
    return try launch(string(params, "app"), session: session, connection: connection)

  case "list_operations":
    return try listOperations(params)

  case "run_operation":
    return try runOperation(params, session: session, connection: connection)

  default:
    break
  }

  guard ["get_window_state", "screenshot", "run_actions"].contains(method) || actionMethods.contains(method) else {
    throw HelperError(code: "unknown_method", message: "Unknown method \(method).")
  }

  let app = try resolve(string(params, "app"))
  try ApprovalGate.require(app, session: session)
  try requireSameProcess(app)
  try connection.throwIfCancelled()
  return try AppLocks.with(app.pid, connection: connection) {
    try connection.throwIfCancelled()
    return try performAppRequest(method, app: app, params: params, session: session)
  }
}

private func performAppRequest(_ method: String, app: AppIdentity, params: JSON, session: ApprovalSession) throws -> Any {
  switch method {
  case "get_window_state":
    return try windowState(app: app, params: params, session: session)

  case "screenshot":
    let application = try applicationElement(app)
    return try captureWindow(pid: app.pid, window: selectWindow(application, params: params))

  case "run_actions":
    try requireAccessibility()
    return try runActions(app: app, params: params, session: session)

  default:
    try requireAccessibility()
    return try acting(app: app, session: session) { try performAction(method, app: app, params: params, session: session) }
  }
}
