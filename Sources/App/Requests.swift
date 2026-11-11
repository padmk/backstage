// The request router. Every request that touches an app resolves it, passes the gate, and proves the process is
// still the one approved, because a pid can be reused while the user reads the window.

import AppKit
import ApplicationServices

func handle(method: String, params: JSON, connection: Connection) throws -> Any {
  let session = connection.session
  switch method {
  case "hello":
    session.lock.withLock {
      session.clientName = params["client_name"] as? String
    }
    // A session handed over from an older command numbers its elements apart from the numbers it held before.
    if let first = params["first_element_number"] as? Int { session.table.startNumbering(at: first) }
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
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let accessibility = AXIsProcessTrustedWithOptions(options)
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
    let query = try string(params, "app")
    let app = try (try? resolve(query)) ?? installedIdentity(try installedApp(query))
    return try requestAddition(app, client: session.lock.withLock { session.clientName } ?? commandLineClient)

  case "list_apps":
    // With app: that one app, running or only installed, without starting it.
    if let query = params["app"] as? String {
      let app = try (try? resolve(query)) ?? installedIdentity(try installedApp(query))
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

  // The recording waits outside the app's lock, which it takes only for its press.
  case "record_audio":
    let app = try resolve(string(params, "app"))
    try ApprovalGate.require(app, session: session)
    try requireSameProcess(app)
    return try recordAudio(app: app, params: params, session: session, connection: connection)

  case "launch_app":
    guard params["files"] == nil || params["files"] is [String] else {
      throw HelperError(code: "invalid_arguments", message: "files must be a list of paths.")
    }
    let files = try (params["files"] as? [String] ?? []).map(openableFile)
    return try launch(string(params, "app"), files: files, session: session, connection: connection)

  case "list_operations":
    return try listOperations(params)

  case "run_operation":
    return try runOperation(params, session: session, connection: connection)

  default:
    break
  }

  guard ["get_window_state", "screenshot", "read_text", "run_actions"].contains(method) || actionMethods.contains(method)
    || windowMethods.contains(method) || ["list_menu_commands", "run_menu_command"].contains(method) else {
    throw HelperError(code: "unknown_method", message: "Unknown method \(method).")
  }

  let app = try resolve(string(params, "app"))
  try ApprovalGate.require(app, session: session)
  try requireSameProcess(app)
  try requireScreenUnlocked(method, params: params, app: app, session: session)
  try connection.throwIfCancelled()
  return try AppLocks.with(app.bundleId, connection: connection) {
    // Checked again after the wait: the user may have removed the app, or it may have quit, meanwhile.
    try ApprovalGate.require(app, session: session)
    try requireSameProcess(app)
    try requireScreenUnlocked(method, params: params, app: app, session: session)
    if method == "run_actions" || method == "run_menu_command" || actionMethods.contains(method) || windowMethods.contains(method) {
      try requireUserNotWorking(in: app)
    }
    try connection.throwIfCancelled()
    if isScreenLocked(), worksOnLockedWindows(method, params: params) {
      if method != "screenshot" { try requireAccessibility() }
      return try lockedWindowRequest(method, app: app, params: params)
    }
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
