// The command line: setting the app up, checking this Mac, and the app list.

import Foundation
import HelperLink

private let grantWait: TimeInterval = 180
private let grantPoll: TimeInterval = 1
private let statusAttempts = 5

private let directories = Directories()

private func client() -> HelperClient {
  HelperClient(directories: directories, managesHelper: true, expectedBuild: appBuildOfOwnBundle())
}

private func printLine(_ text: String) {
  print(text)
  fflush(stdout)
}

// MARK: setup

// The MCP clients setup registers with, each through its own command, at user scope.
private struct MCPClient: Sendable {
  let name: String
  let command: String
  let remove: @Sendable (String) -> [String]
  let add: @Sendable (String, [String]) -> [String]
}

private let mcpClients = [
  MCPClient(name: "Claude Code", command: "claude", remove: { ["mcp", "remove", $0, "-s", "user"] }, add: { ["mcp", "add", "-s", "user", $0, "--"] + $1 }),
  MCPClient(name: "Codex", command: "codex", remove: { ["mcp", "remove", $0] }, add: { ["mcp", "add", $0, "--"] + $1 }),
]

private func findCommand(_ name: String) -> String? {
  // Clients install into places a login shell adds to PATH, which an app or a script may not have.
  let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.npm-global/bin"]
  let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + extra
  return path.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

private func register() -> Bool {
  var ok = true
  let server = [installedCommandPath, "mcp"]
  for client in mcpClients {
    guard let command = findCommand(client.command) else { continue }
    // Removing first only clears an old entry; one that is not there fails harmlessly.
    _ = try? runProcess(command, client.remove(Product.commandName), timeout: 60, allowFailure: true)
    let arguments = client.add(Product.commandName, server)
    do {
      try runProcess(command, arguments, timeout: 60)
      printLine("Registered the \"\(Product.commandName)\" MCP server with \(client.name). Restart its sessions to use it.")
    } catch {
      // The earlier registration is already gone, so the user gets the command to add it back by hand.
      let shown = arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
      printLine("Could not register the \"\(Product.commandName)\" MCP server with \(client.name). Run: \(client.command) \(shown)")
      ok = false
    }
  }
  return ok
}

private func openPane(_ pane: String) {
  // Opening System Settings only helps; the printed text says where to go.
  _ = try? runProcess("/usr/bin/open", [Product.privacyPaneURL(pane)], timeout: 15, allowFailure: true)
}

private func status(_ helper: HelperClient) throws -> JSON {
  for attempt in 1... {
    do {
      return try helper.request("status") as? JSON ?? [:]
    } catch {
      if attempt >= statusAttempts { throw error }
      Thread.sleep(forTimeInterval: grantPoll)
    }
  }
  return [:]
}

// macOS asks only once per service, so the Settings pane is the only prompt left after a refusal. A running
// process sees a new Accessibility grant, so the wait only polls.
private func waitForAccessibility(_ helper: HelperClient) -> Bool {
  let started = Date()
  var shownPane = false
  while Date().timeIntervalSince(started) < grantWait {
    // A helper that does not answer yet is asked again until the deadline.
    if let current = try? helper.request("status") as? JSON, current["accessibility"] as? Bool == true { return true }
    if !shownPane {
      openPane("Privacy_Accessibility")
      shownPane = true
      // macOS may leave the list empty, and then the app has to be added by hand.
      _ = try? runProcess("/usr/bin/open", ["-R", Product.installedAppPath], timeout: 15, allowFailure: true)
      printLine("If \(Product.appName) is not listed in the pane, drag it there from the Finder window: \(Product.installedAppPath)")
    }
    Thread.sleep(forTimeInterval: grantPoll)
  }
  return false
}

private func resetGrant(_ service: String) {
  // The failure is printed; tccutil's reason adds nothing the user can act on.
  if (try? runProcess("/usr/bin/tccutil", ["reset", service, Product.bundleIdentifier], timeout: 30)) == nil {
    printLine("Could not reset \(service).")
  }
}

// Accessibility is the one permission setup needs. Screen Recording, for screenshots, and System Audio Recording, for
// record_audio, are optional and turned on later in the window, so setup shows no second prompt.
// Returns whether Accessibility is granted, and whether it already was, as on an update.
private func grantPermissions(signingChanged: Bool) throws -> (granted: Bool, already: Bool) {
  let helper = client()
  defer { helper.close() }
  let current = try status(helper)
  // Entries for an earlier signature can still look enabled while they no longer apply.
  if signingChanged, current["screen_recording"] as? Bool != true { resetGrant("ScreenCapture") }
  if signingChanged, current["audio_recording"] as? String == "denied" { resetGrant("AudioCapture") }
  if current["accessibility"] as? Bool == true { return (true, true) }
  if signingChanged { resetGrant("Accessibility") }
  printLine("Grant Accessibility to \(Product.appName) in the macOS window that opens, so it can read windows, click and type.")
  do {
    _ = try helper.request("request_permissions")
  } catch {
    printLine("macOS did not show its prompt: \(describe(error))")
  }
  let granted = waitForAccessibility(helper)
  if !granted { printLine("Accessibility is still missing. Run this command again after granting it.") }
  return (granted, false)
}

private func setup(register shouldRegister: Bool) throws -> Int32 {
  if let problem = platformProblem() { throw HelperFailure(code: nil, message: problem) }
  guard let source = ownBundlePath() else {
    throw HelperFailure(code: nil, message: "Run setup from \(Product.appName).app: build it with make app, then run build/\(Product.appName).app/\(Product.commandRelativePath) setup.")
  }
  let installer = Installer(directories: directories)
  printLine("Installing \(Product.appName) into \((installer.installTarget() as NSString).deletingLastPathComponent)...")
  _ = try installer.install(from: source)
  let (granted, already) = try grantPermissions(signingChanged: installer.takeSigningChange())
  var status: Int32 = granted ? 0 : 1
  if shouldRegister, !register() { status = 1 }
  if granted, already {
    // An update: the user is working in another app, so nothing comes forward.
    printLine("\(Product.appName) is up to date. Its window, opened from \(Product.installedAppPath), shows the apps agents may use and its settings.")
  } else if granted {
    // A running helper would only bring back its last tab, so a fresh one is opened on Apps.
    let helper = client()
    // A helper that is not running has nothing to quit.
    _ = try? helper.request("quit")
    helper.close()
    Thread.sleep(forTimeInterval: 0.5)
    // Opening the window only helps; setup has finished either way.
    _ = try? runProcess("/usr/bin/open", [Product.installedAppPath, "--args", Product.tabArgument, "apps"], timeout: 15, allowFailure: true)
    printLine("\(Product.appName) is open: on the Apps tab, add the apps agents may use, or turn on Allow every app. macOS asks once for what an added app's ready operations need. Screen Recording, for screenshots, is optional, on the Setup tab.")
  }
  printLine("For another MCP client, use this stdio server:")
  printLine(String(decoding: try JSONSerialization.data(withJSONObject: ["command": installedCommandPath, "args": ["mcp"]], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
  return status
}

// MARK: doctor

private func doctor() -> Int32 {
  let installer = Installer(directories: directories)
  var checks: [(String, Bool, String)] = []
  let problem = platformProblem()
  let version = ProcessInfo.processInfo.operatingSystemVersion
  checks.append(("Apple silicon and macOS \(Product.minimumMacOS) or newer", problem == nil, problem ?? "macOS \(version.majorVersion).\(version.minorVersion)"))
  let installed = installer.isOurApp(Product.installedAppPath) && installer.isSignedHere(Product.installedAppPath)
  let current = ownBundlePath().map { $0 == Product.installedAppPath || installer.installedMatches($0) } ?? installed
  let appDetail = !installed ? "not installed or not signed on this Mac; run: \(commandHint()) setup"
    : !current ? "another build than this command; run: \(commandHint()) setup" : Product.installedAppPath
  checks.append(("App", installed && current, appDetail))
  var screenRecording: Bool?
  var audioRecording: String?
  var appAccess: [JSON] = []
  var privateCalls: [String: Bool] = [:]
  if installed && current {
    let helper = client()
    do {
      let reply = try helper.request("status") as? JSON ?? [:]
      let accessibility = reply["accessibility"] as? Bool == true
      checks.append(("Accessibility", accessibility, accessibility ? "granted" : "missing; run: \(commandHint()) setup"))
      screenRecording = reply["screen_recording"] as? Bool
      audioRecording = reply["audio_recording"] as? String
      appAccess = reply["app_access"] as? [JSON] ?? []
      privateCalls = reply["private_calls"] as? [String: Bool] ?? [:]
    } catch {
      checks.append(("App running", false, describe(error)))
    }
    helper.close()
  }
  for (name, passed, detail) in checks { printLine("\(passed ? "ok  " : "FAIL") \(name): \(detail)") }
  if let screenRecording {
    printLine("\(screenRecording ? "ok  " : "--  ") Screen Recording: \(screenRecording ? "granted" : "optional, for screenshots; turn it on in the \(Product.appName) window, on the Setup tab")")
  }
  // Optional: each only matters for the operations that use it, so a missing one is not a failure.
  let meaning = ["granted": "granted", "not_asked": "not asked yet", "denied": "off in System Settings", "unknown": "shown once the app runs"]
  if let audioRecording {
    let detail = audioRecording == "granted" ? "granted"
      : audioRecording == "unknown" ? "cannot be checked on this version of macOS, so record_audio is not available"
      : "optional, for record_audio; allow it in the \(Product.appName) window, on the Setup tab (\(meaning[audioRecording] ?? audioRecording))"
    printLine("\(audioRecording == "granted" ? "ok  " : "--  ") System Audio Recording: \(detail)")
  }
  if !appAccess.isEmpty { printLine("App access for the listed apps (allow them in the \(Product.appName) window):") }
  for entry in appAccess {
    let state = entry["state"] as? String ?? ""
    printLine("\(state == "granted" ? "ok  " : "--  ") \(entry["name"] as? String ?? ""): \(meaning[state] ?? state)")
  }
  // Background delivery and capture while locked use private macOS calls; a missing one degrades, it does not fail.
  let missing = privateCalls.filter { !$0.value }.keys.sorted()
  if !privateCalls.isEmpty {
    printLine("\(missing.isEmpty ? "ok  " : "--  ") Private macOS calls: \(missing.isEmpty ? "all found" : "missing \(missing.joined(separator: ", ")); the actions that use them fall back or report it")")
  }
  return checks.allSatisfy(\.1) ? 0 : 1
}

// MARK: uninstall

// Takes the app out: no login item, no MCP registrations, the app in the Trash. Settings, the app list and the
// signing identity stay, so a later setup keeps the permissions; --reset removes them too, after a confirmation.
private func uninstall(reset: Bool) throws -> Int32 {
  if reset {
    print("This also removes the app list, the activity log, the settings, the signing identity and the macOS permissions of \(Product.appName). Type yes to go on: ", terminator: "")
    fflush(stdout)
    guard readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "yes" else {
      printLine("Nothing was removed.")
      return 1
    }
  }
  // A test home never reaches the installed app, the Trash, the MCP clients or the macOS permissions.
  guard ProcessInfo.processInfo.environment["HELPER_TEST_HOME"] == nil else {
    printLine("A test home is set, so nothing was removed.")
    return 1
  }
  let helper = HelperClient(directories: directories, managesHelper: false, expectedBuild: nil)
  // A helper that is not running has nothing to prepare.
  _ = try? helper.request("prepare_uninstall")
  helper.close()
  Thread.sleep(forTimeInterval: 0.5)
  for client in mcpClients {
    guard let command = findCommand(client.command) else { continue }
    // Only the clients whose entry was removed are reported; the others are left as they are.
    if (try? runProcess(command, client.remove(Product.commandName), timeout: 60)) != nil {
      printLine("Removed the \"\(Product.commandName)\" MCP server from \(client.name).")
    }
  }
  for location in Product.appLocations where FileManager.default.fileExists(atPath: location) {
    let installer = Installer(directories: directories)
    guard installer.isOurApp(location) else {
      printLine("\(location) is another app, so it stays.")
      continue
    }
    try FileManager.default.trashItem(at: URL(fileURLWithPath: location), resultingItemURL: nil)
    printLine("Moved \(location) to the Trash.")
  }
  if reset {
    for directory in Set([directories.config, directories.data, directories.state]) where FileManager.default.fileExists(atPath: directory) {
      try FileManager.default.trashItem(at: URL(fileURLWithPath: directory), resultingItemURL: nil)
      printLine("Moved \(directory) to the Trash.")
    }
    // Nothing to delete is no failure of an uninstall.
    _ = try? runProcess("/usr/bin/defaults", ["delete", Product.bundleIdentifier], timeout: 15, allowFailure: true)
    // Nothing to reset is no failure of an uninstall.
    _ = try? runProcess("/usr/bin/tccutil", ["reset", "All", Product.bundleIdentifier], timeout: 30, allowFailure: true)
    printLine("Removed the macOS permissions of \(Product.appName) and what macOS keeps for it, such as window sizes.")
  } else {
    printLine("The app list, the settings and the signing identity stay, so a later setup keeps the permissions. To remove them too, run: \(Product.commandName) uninstall --reset")
  }
  return 0
}

// MARK: approvals

private func approvals(_ arguments: [String]) throws -> Int32 {
  let helper = HelperClient(directories: Directories(testHome: ProcessInfo.processInfo.environment["HELPER_TEST_HOME"]),
                            managesHelper: ProcessInfo.processInfo.environment["HELPER_NO_START"] == nil, expectedBuild: appBuildOfOwnBundle())
  defer { helper.close() }
  let subcommand = arguments.first
  let target = arguments.count > 1 ? arguments[1] : nil
  switch (subcommand, target) {
  case (nil, _), ("list", _):
    let listed = (try helper.request("approvals_list") as? JSON)?["approvals"] as? [JSON] ?? []
    printLine(listed.isEmpty ? "No apps on the list." : listed.map { "\($0["bundle_id"] as? String ?? "") (\($0["signer"] as? String ?? ""))" }.joined(separator: "\n"))
    return 0
  case ("add", let app?):
    do {
      let added = try helper.request("approvals_add", ["app": app]) as? JSON ?? [:]
      // Asked for from here, an app waits until the user adds it in the window, where the request now shows.
      if let pending = added["pending"] as? String {
        printLine("\(added["name"] as? String ?? app) (\(pending)) waits for you: add it in the \(Product.appName) window, on the Apps tab.")
        return 0
      }
      printLine("Added \(added["name"] as? String ?? app) (\(added["added"] as? String ?? "")).")
      return 0
    } catch let failure as HelperFailure where failure.code != nil {
      printLine("\(failure.code!): \(failure.message)")
      return 1
    }
  case ("revoke", let bundleId?):
    let revoked = (try helper.request("approvals_revoke", ["bundle_id": bundleId]) as? JSON)?["revoked"] as? Bool == true
    printLine(revoked ? "Removed \(bundleId)." : "\(bundleId) is not on the list.")
    return revoked ? 0 : 1
  default:
    return usage()
  }
}

// MARK: Dispatch

private func usage() -> Int32 {
  let name = Product.commandName
  FileHandle.standardError.write(Data("""
  Usage:
    \(name) setup [--no-register]     Install the app, ask for Accessibility, register with Claude Code and Codex
    \(name) doctor                    Check this Mac
    \(name) approvals [list]          List the apps agents may use
    \(name) approvals add <app>       Add an app by name or bundle id
    \(name) approvals revoke <bundle-id> Remove an app from the list
    \(name) uninstall [--reset]       Remove the app, its login item and MCP registrations; --reset also its data
    \(name) mcp                       Serve MCP over stdio (MCP clients run this)
    \(name) version

  """.utf8))
  return 2
}

func describe(_ error: Error) -> String {
  if let failure = error as? HelperFailure { return failure.code.map { "\($0): \(failure.message)" } ?? failure.message }
  return "\(error)"
}

func runCommand(_ arguments: [String]) -> Int32 {
  do {
    switch arguments.first {
    case "setup": return try setup(register: !arguments.contains("--no-register"))
    case "doctor": return doctor()
    case "uninstall": return try uninstall(reset: arguments.contains("--reset"))
    case "approvals": return try approvals(Array(arguments.dropFirst()))
    case "version":
      printLine(Product.version)
      return 0
    default: return usage()
    }
  } catch {
    FileHandle.standardError.write(Data("\(Product.commandName): \(describe(error))\n".utf8))
    return 1
  }
}
