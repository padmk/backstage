// The request router. Every request that touches an app resolves it, passes the gate, and proves the process is
// still the one approved, because a pid can be reused while the user reads the window.

import AppKit
import ApplicationServices

func handle(method: String, params: JSON, connection: Connection) throws -> Any {
  let session = connection.session
  switch method {
  case "hello":
    session.lock.withLock {
      session.clientName = sessionClientName(params["client_name"])
    }
    // A session handed over from an older command numbers its elements apart from the numbers it held before.
    if let first = params["first_element_number"] as? Int ?? (params["element_number_limit"] != nil ? 1 : nil) {
      session.table.startNumbering(at: first, limit: params["element_number_limit"] as? Int)
    }
    return ["version": Configuration.version, "build": Configuration.build] as JSON

  case "status":
    return [
      "accessibility": AXIsProcessTrusted(), "screen_recording": CGPreflightScreenCaptureAccess(), "version": Configuration.version, "build": Configuration.build,
      "audio_recording": permissionState(.audioRecording).rawValue,
      "screen_locked": isScreenLocked(), "private_calls": privateCallAvailability(),
      // The same grants as the Setup tab: those of the listed apps.
      "app_access": appGrants(forListed: Set(ApprovalStore.list().compactMap { $0["bundle_id"] }), everyApp: Preferences.allowsEveryApp)
        .map { ["name": $0.name, "state": grantState($0).rawValue] as JSON },
    ] as JSON

  case "request_permissions":
    let accessibility = isTrustedAskingForAccessibility()
    // Screen Recording is optional and asked for only when the user chooses Allow in the window, never over the socket.
    return ["accessibility": accessibility, "screen_recording": CGPreflightScreenCaptureAccess()] as JSON

  case "quit":
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      unlink(Configuration.socketPath)
      exit(0)
    }
    return [:] as JSON

  // Before the app goes to the Trash: it no longer starts at login or shows in the menu bar, and it quits.
  case "prepare_uninstall":
    // Uninstalling goes on: a login item left behind points at a removed app, which macOS skips.
    if Preferences.isInstalledCopy, LaunchAtLogin.state != .off { try? LaunchAtLogin.set(false) }
    Preferences.showsMenuBarItem = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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
    let app = try requestedApp(string(params, "app"))
    return try requestAddition(app, client: session.lock.withLock { session.clientName } ?? commandLineClient)

  // Asked by the command before it opens ssh to another Mac.
  case "require_computer":
    try requireAllowedComputer(string(params, "computer"), client: session.lock.withLock { session.clientName } ?? commandLineClient)
    return ["allowed": true] as JSON

  case "list_apps":
    // With app: that one app, running or only installed, without starting it.
    if let query = params["app"] as? String {
      let app = try requestedApp(query)
      return ["app": ["name": app.name, "bundle_id": app.bundleId, "running": app.pid != 0, "access": ApprovalGate.access(app).rawValue],
              "every_app": Preferences.allowsEveryApp, "screen_locked": isScreenLocked(), "windows_while_locked": Preferences.worksInWindowsWhileLocked] as JSON
    }
    return ["apps": visibleApps().map { running in
      var entry = describe(running)
      entry["access"] = ApprovalGate.access(identity(of: running)).rawValue
      return entry
    }, "every_app": Preferences.allowsEveryApp, "screen_locked": isScreenLocked(), "windows_while_locked": Preferences.worksInWindowsWhileLocked] as JSON

  case "list_windows":
    return try listWindows(params: params)

  // It takes the app's lock for each look rather than for the whole wait.
  case "wait_for":
    let app = try resolve(string(params, "app"))
    try ApprovalGate.require(app, session: session)
    try requireAccessibility()
    return try waitFor(app: app, params: params, connection: connection)

  case "launch_app":
    guard params["files"] == nil || params["files"] is [String] else {
      throw HelperError(code: "invalid_arguments", message: "files must be a list of paths.")
    }
    return try launch(string(params, "app"), files: params["files"] as? [String] ?? [], session: session, connection: connection)

  case "list_operations":
    return try listOperations(params)

  case "run_operation":
    return try runOperation(params, session: session, connection: connection)

  default:
    break
  }

  guard ["get_window_state", "screenshot", "read_text", "run_actions", "record_audio"].contains(method) || actionMethods.contains(method)
    || windowMethods.contains(method) || ["list_menu_commands", "run_menu_command"].contains(method) else {
    throw HelperError(code: "unknown_method", message: "Unknown method \(method).")
  }

  let app = try resolve(string(params, "app"))
  try ApprovalGate.require(app, session: session)
  try requireSameProcess(app)
  try requireScreenUnlocked(method, params: params, app: app, session: session)
  try connection.throwIfStopped()
  return try AppLocks.with(app.bundleId, connection: connection) {
    // Checked again after the wait: the user may have removed the app, or it may have quit, meanwhile.
    try ApprovalGate.require(app, session: session)
    try requireSameProcess(app)
    try requireScreenUnlocked(method, params: params, app: app, session: session)
    if ["run_actions", "run_menu_command", "record_audio"].contains(method) || actionMethods.contains(method) || windowMethods.contains(method) {
      try requireUserNotWorking(in: app)
    }
    try connection.throwIfStopped()
    if isScreenLocked(), worksOnLockedWindows(method, params: params) {
      if method != "screenshot" { try requireAccessibility() }
      return try lockedWindowRequest(method, app: app, params: params)
    }
    return try performAppRequest(method, app: app, params: params, session: session, connection: connection)
  }
}

// An app a request names, running or only installed. A bundle id that is never available is answered as such
// even when this Mac does not have it.
private func requestedApp(_ query: String) throws -> AppIdentity {
  // resolve fails only for an app that is not running; the installed app answers for it.
  if let app = try? resolve(query) { return app }
  do {
    return try installedIdentity(try installedApp(query))
  } catch where isNeverApproved(query) {
    return AppIdentity(pid: 0, bundleId: query, name: query, processStart: nil, path: nil)
  }
}

private func performAppRequest(_ method: String, app: AppIdentity, params: JSON, session: ApprovalSession, connection: Connection) throws -> Any {
  switch method {
  case "record_audio":
    return try recordAudio(app: app, params: params, session: session, connection: connection)

  case "get_window_state":
    return try windowState(app: app, params: params, session: session)

  case "screenshot":
    let application = try applicationElement(app)
    return try captureWindow(pid: app.pid, window: selectWindow(application, params: params), recognizeText: params["text"] as? Bool == true)

  case "read_text":
    try requireAccessibility()
    return try readText(app: app, params: params, session: session)

  case "run_actions":
    try requireAccessibility()
    return try runActions(app: app, params: params, session: session)

  case "list_menu_commands":
    return try listMenuCommands(app: app, params: params, session: session)

  case "run_menu_command":
    return try acting(app: app, session: session) { try runMenuCommand(app: app, params: params, session: session) }

  case "set_window":
    return try setWindow(app: app, params: params)

  case "set_app_state":
    return try setAppState(app: app, params: params)

  case "close":
    return try closeWindowOrApp(app: app, params: params)

  default:
    try requireAccessibility()
    return try acting(app: app, session: session) { try performAction(method, app: app, params: params, session: session) }
  }
}
