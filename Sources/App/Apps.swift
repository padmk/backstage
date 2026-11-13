// Finding the app a request names, running or installed, and starting one in the background or handing it files.

import AppKit
import ApplicationServices

private let launchTimeoutSeconds = 20
// How long a starting app is watched for taking the focus, and how long it must leave it alone once started.
private let launchFocusWatchSeconds = 8.0
private let launchQuietSeconds = 1.5
// How long an app started hidden for an operation may take to finish starting.
private let startSeconds = 20.0

// Runs AppKit work on the main thread, at once when already there, and waits for its result.
func onMain<T: Sendable>(_ work: @MainActor () throws -> T) rethrows -> T {
  if Thread.isMainThread { return try MainActor.assumeIsolated(work) }
  return try DispatchQueue.main.sync { try MainActor.assumeIsolated(work) }
}

func describe(_ app: NSRunningApplication) -> JSON {
  [
    "pid": Int(app.processIdentifier), "name": app.localizedName ?? "", "bundle_id": app.bundleIdentifier ?? "",
    "active": app.isActive, "hidden": app.isHidden,
  ]
}

func visibleApps() -> [NSRunningApplication] {
  onMain { NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular } }
}

func identity(of app: NSRunningApplication) -> AppIdentity {
  AppIdentity(
    pid: app.processIdentifier, bundleId: app.bundleIdentifier ?? "", name: app.localizedName ?? app.bundleIdentifier ?? "app",
    launchDate: app.launchDate, path: app.bundleURL?.path)
}

// Apps with a Dock icon first. An app without one, such as Control Center, is reachable only when it has items
// in the menu bar, which are often its only interface; system processes such as the Dock stay out of reach.
func resolve(_ query: String) throws -> AppIdentity {
  let lowered = query.lowercased()
  let find = { (apps: [NSRunningApplication]) in
    apps.first { $0.bundleIdentifier?.lowercased() == lowered }
      ?? apps.first { $0.localizedName?.lowercased() == lowered }
      ?? Int(query).flatMap { pid in apps.first { Int($0.processIdentifier) == pid } }
  }
  let match = find(visibleApps()) ?? find(onMain { NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .accessory } })
    .flatMap { app in hasMenuExtras(pid: app.processIdentifier) ? app : nil }
  guard let match else {
    throw HelperError(code: "app_not_found", message: "\(query) is not running. Use launch_app first.")
  }
  return identity(of: match)
}

private func hasMenuExtras(pid: pid_t) -> Bool {
  AXIsProcessTrusted() && attribute(AXUIElementCreateApplication(pid), "AXExtrasMenuBar") != nil
}

func requireSameProcess(_ app: AppIdentity) throws {
  let current = onMain { NSRunningApplication(processIdentifier: app.pid) }
  guard let current, !current.isTerminated, current.bundleIdentifier == app.bundleId, current.launchDate == app.launchDate else {
    throw HelperError(code: "app_changed", message: "\(app.name) stopped while waiting. Try again.")
  }
}

// Only names, never paths, so a request cannot point the helper at a bundle of its choosing.
func installedApp(_ query: String) throws -> URL {
  guard !query.contains("/"), !query.contains("\0") else {
    throw HelperError(code: "invalid_request", message: "Give an app name or bundle id, not a path.")
  }
  let url: URL? = onMain {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: query)
      ?? ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"].lazy
        .map { URL(fileURLWithPath: "\($0)/\(query).app") }
        .first { FileManager.default.fileExists(atPath: $0.path) }
  }
  guard let url else { throw HelperError(code: "app_not_found", message: "\(query) is not installed.") }
  return url
}

func installedIdentity(_ url: URL) throws -> AppIdentity {
  guard let bundleId = Bundle(url: url)?.bundleIdentifier else {
    throw HelperError(code: "app_not_found", message: "\(url.lastPathComponent) has no bundle identifier.")
  }
  return AppIdentity(pid: 0, bundleId: bundleId, name: url.deletingPathExtension().lastPathComponent, launchDate: nil, path: url.path)
}

// With files, the app opens them, started if it is not running. Apps often come forward to show a file they were
// handed, so the app the user was in gets the focus back then too.
func launch(_ query: String, files paths: [String] = [], session: ApprovalSession, connection: Connection) throws -> JSON {
  let url = try installedApp(query)
  guard let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier else {
    throw HelperError(code: "app_not_found", message: "\(query) has no bundle identifier.")
  }
  let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
  let approved = AppIdentity(pid: 0, bundleId: bundleId, name: name, launchDate: nil, path: url.path)
  try ApprovalGate.require(approved, session: session)
  // Paths are looked at only for an allowed app, so a refusal says nothing about which files exist.
  let files = try paths.map(openableFile)
  guard !files.isEmpty else {
    // Opening a running app sends it a reopen event, which can show a window and take the focus, so it is left as it is.
    if let running = runningApp(bundleId) {
      var result = describe(running)
      result["already_running"] = true
      return result
    }
    return try openInApp(url, files: [], bundleId: bundleId, name: name)
  }
  // Files reach the app in turn with other requests for it, so a document does not open under another agent's typing.
  return try AppLocks.with(bundleId, connection: connection) {
    try ApprovalGate.require(approved, session: session)
    // Files arriving while the user works in the app would mix with what they do there.
    if let running = runningApp(bundleId) { try requireUserNotWorking(in: identity(of: running)) }
    try connection.throwIfCancelled()
    return try openInApp(url, files: files, bundleId: bundleId, name: name)
  }
}

private func runningApp(_ bundleId: String) -> NSRunningApplication? {
  onMain { NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first { !$0.isTerminated } }
}

// NSWorkspace's answer to a launch, as the launched app or why it did not start.
private func launchHandler(_ outcome: AsyncOutcome<NSRunningApplication>, name: String) -> @Sendable (NSRunningApplication?, (any Error)?) -> Void {
  { app, error in
    if let app {
      outcome.set(.success(app))
    } else {
      outcome.set(.failure(error.map { HelperError(code: "action_failed", message: $0.localizedDescription) }
        ?? HelperError(code: "action_failed", message: "\(name) did not start.")))
    }
  }
}

private func launchResult(_ result: Result<NSRunningApplication, any Error>?, name: String) throws -> NSRunningApplication {
  guard let result else { throw HelperError(code: "timeout", message: "\(name) did not start in time.") }
  return try result.get()
}

// Starts the app, or hands a running one the files, and keeps the focus where it was.
private func openInApp(_ url: URL, files: [URL], bundleId: String, name: String) throws -> JSON {
  let frontBefore = onMain { NSWorkspace.shared.frontmostApplication }
  let configuration = NSWorkspace.OpenConfiguration()
  configuration.activates = false
  configuration.addsToRecentItems = false
  let outcome = AsyncOutcome<NSRunningApplication>()
  let opened = launchHandler(outcome, name: name)
  if files.isEmpty {
    NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: opened)
  } else {
    NSWorkspace.shared.open(files, withApplicationAt: url, configuration: configuration, completionHandler: opened)
  }
  // The app can take the focus before the launch is reported, so it is watched while waiting too.
  let launchDeadline = Date().addingTimeInterval(TimeInterval(launchTimeoutSeconds))
  var returnedEarly = false
  var result = outcome.wait(until: .now() + 0.05)
  while result == nil {
    if let frontBefore, frontBefore.bundleIdentifier != bundleId,
       onMain({ NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) == bundleId {
      returnedEarly = onMain { frontBefore.activate() } || returnedEarly
    }
    guard Date() < launchDeadline else { throw HelperError(code: "timeout", message: "\(name) did not start in time.") }
    result = outcome.wait(until: .now() + 0.05)
  }
  let launched = try launchResult(result, name: name)
  let focusReturned = keepFocusWhileStarting(launched, previous: frontBefore) || returnedEarly
  var reply = describe(launched)
  if focusReturned { reply["focus_returned"] = true }
  if !files.isEmpty { reply["opened"] = files.map(\.path) }
  return reply
}

// Many apps activate themselves as they start, despite the request not to. While it starts, the app the user
// was in gets the focus back each time, which also leaves the new app's windows behind it. Returns whether it had to.
private func keepFocusWhileStarting(_ launched: NSRunningApplication, previous: NSRunningApplication?) -> Bool {
  guard let previous, previous.processIdentifier != launched.processIdentifier else { return false }
  let deadline = Date().addingTimeInterval(launchFocusWatchSeconds)
  var quietSince = Date()
  var returned = false
  while Date() < deadline, !launched.isTerminated {
    if onMain({ NSWorkspace.shared.frontmostApplication?.processIdentifier }) == launched.processIdentifier {
      returned = onMain { previous.activate() } || returned
      quietSince = Date()
    } else if launched.isFinishedLaunching, Date().timeIntervalSince(quietSince) >= launchQuietSeconds {
      break
    }
    sleep(seconds: 0.05)
  }
  return returned
}

// Starts an app hidden and behind the user's work, without the windows it had open when it last quit, and waits
// until it has finished starting, because Apple events sent before then can go unanswered.
func startAppHidden(at path: String, name: String) throws -> NSRunningApplication {
  let configuration = NSWorkspace.OpenConfiguration()
  configuration.activates = false
  configuration.hides = true
  configuration.addsToRecentItems = false
  // Without it the app reopens the windows it had when it last quit, which can show alerts no one sees.
  configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
  let outcome = AsyncOutcome<NSRunningApplication>()
  NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration, completionHandler: launchHandler(outcome, name: name))
  let deadline = Date().addingTimeInterval(startSeconds)
  guard let result = outcome.wait(until: .now() + startSeconds) else {
    throw HelperError(code: "timeout", message: "\(name) did not start in time.")
  }
  let launched = try launchResult(result, name: name)
  // Apple events sent before the app has finished starting can go unanswered.
  while !launched.isFinishedLaunching, Date() < deadline { sleep(seconds: 0.05) }
  return launched
}
