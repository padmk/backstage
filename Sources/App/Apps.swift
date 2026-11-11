// Finding the app a request names, running or installed, and starting one in the background or handing it files.

import AppKit
import ApplicationServices

private let launchTimeoutSeconds = 20
// How long a starting app is watched for taking the focus, and how long it must leave it alone once started.
private let launchFocusWatchSeconds = 8.0
private let launchQuietSeconds = 1.5
// How long an app started hidden for an operation may take to finish starting.
private let startSeconds = 20.0

func onMain<T>(_ work: () -> T) -> T {
  Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
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
func launch(_ query: String, files: [URL] = [], session: ApprovalSession, connection: Connection) throws -> JSON {
  let url = try installedApp(query)
  guard let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier else {
    throw HelperError(code: "app_not_found", message: "\(query) has no bundle identifier.")
  }
  let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
  try ApprovalGate.require(
    AppIdentity(pid: 0, bundleId: bundleId, name: name, launchDate: nil, path: url.path), session: session)

  // Opening a running app sends it a reopen event, which can show a window and take the focus, so it is left as it is.
  let running = onMain { NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first { !$0.isTerminated } }
  if let running, files.isEmpty {
    var result = describe(running)
    result["already_running"] = true
    return result
  }
  // Files arriving while the user works in the app would mix with what they do there.
  if let running { try requireUserNotWorking(in: identity(of: running)) }
  let frontBefore = onMain { NSWorkspace.shared.frontmostApplication }
  let configuration = NSWorkspace.OpenConfiguration()
  configuration.activates = false
  configuration.addsToRecentItems = false
  let done = DispatchSemaphore(value: 0)
  var launched: NSRunningApplication?
  var failure: Error?
  let opened: (NSRunningApplication?, Error?) -> Void = { app, error in
    launched = app
    failure = error
    done.signal()
  }
  if files.isEmpty {
    NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: opened)
  } else {
    NSWorkspace.shared.open(files, withApplicationAt: url, configuration: configuration, completionHandler: opened)
  }
  // The app can take the focus before the launch is reported, so it is watched while waiting too.
  let launchDeadline = Date().addingTimeInterval(TimeInterval(launchTimeoutSeconds))
  var returnedEarly = false
  while done.wait(timeout: .now() + 0.05) == .timedOut {
    if let frontBefore, frontBefore.bundleIdentifier != bundleId,
       onMain({ NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) == bundleId {
      returnedEarly = onMain { frontBefore.activate() } || returnedEarly
    }
    guard Date() < launchDeadline else { throw HelperError(code: "timeout", message: "\(name) did not start in time.") }
  }
  if let failure { throw HelperError(code: "action_failed", message: failure.localizedDescription) }
  guard let launched else { throw HelperError(code: "action_failed", message: "\(name) did not start.") }
  let focusReturned = keepFocusWhileStarting(launched, previous: frontBefore) || returnedEarly
  var result = describe(launched)
  if focusReturned { result["focus_returned"] = true }
  if !files.isEmpty { result["opened"] = files.map(\.path) }
  return result
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
  let done = DispatchSemaphore(value: 0)
  var launched: NSRunningApplication?
  var failure: Error?
  NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) { app, error in
    launched = app
    failure = error
    done.signal()
  }
  let deadline = Date().addingTimeInterval(startSeconds)
  guard done.wait(timeout: .now() + startSeconds) == .success else {
    throw HelperError(code: "timeout", message: "\(name) did not start in time.")
  }
  if let failure { throw HelperError(code: "action_failed", message: failure.localizedDescription) }
  guard let launched else { throw HelperError(code: "action_failed", message: "\(name) did not start.") }
  // Apple events sent before the app has finished starting can go unanswered.
  while !launched.isFinishedLaunching, Date() < deadline { sleep(seconds: 0.05) }
  return launched
}
