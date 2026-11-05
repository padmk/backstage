// The app list. Agents may use an app through Backstage only when the user put it on the list in the Backstage
// window, or turned on Allow every app; nothing asks during a task. It lives in the helper, which holds the macOS
// permissions, so a process that reaches the socket directly meets the same check as an agent using the MCP
// tools. It guards against mistakes and agents limited to Backstage, not against an agent with a shell, which can
// control the Mac without Backstage or edit approvals.json, a file with file permissions only.

import AppKit
import Security

struct AppIdentity {
  let pid: pid_t
  let bundleId: String
  let name: String
  let launchDate: Date?
  let path: String?
}

private let neverApproved: Set<String> = [
  "com.apple.SecurityAgent", "com.apple.loginwindow", "com.apple.LocalAuthentication.UIAgent",
  "com.apple.Passwords", "com.apple.keychainaccess",
  // The windows in which macOS asks for a permission.
  "com.apple.tcc.AuthorizationPromptService", "com.apple.UserNotificationCenter",
]

// These apps can run commands or change the system, so allowing one gives agents far more than the app; the list
// says so next to them.
private let farReaching: Set<String> = [
  "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
  "dev.warp.Warp-Stable", "com.github.wez.wezterm", "com.apple.ScriptEditor2", "com.apple.Automator",
  "com.apple.shortcuts", "com.apple.systempreferences", "com.apple.finder", "com.apple.dt.Xcode",
  "com.microsoft.VSCode", "dev.zed.Zed",
]

func isFarReaching(_ bundleId: String) -> Bool { farReaching.contains(bundleId) }
// Whole families too: Passwords has helpers such as its menu bar extra under its own prefix.
private let neverApprovedPrefixes = ["com.apple.Passwords.", "com.apple.keychainaccess."]

func isNeverApproved(_ bundleId: String) -> Bool {
  neverApproved.contains(bundleId) || neverApprovedPrefixes.contains { bundleId.hasPrefix($0) } || bundleId == Bundle.main.bundleIdentifier
}

private let maxClientNameLength = 40

// The client names itself, so the name is kept to one short line in the Activity list and the menu.
func readableClientName(_ name: String?) -> String? {
  let printable = (name ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
  let words = String(String.UnicodeScalarView(printable)).split(whereSeparator: { "-_ ".contains($0) })
  guard !words.isEmpty else { return nil }
  let readable = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
  return readable.count > maxClientNameLength ? String(readable.prefix(maxClientNameLength - 1)) + "…" : readable
}

// An app's name as one short line without control characters, for messages agents read.
func readableAppName(_ name: String) -> String? {
  let printable = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }))
    .trimmingCharacters(in: .whitespaces)
  guard !printable.isEmpty else { return nil }
  return printable.count > maxClientNameLength ? String(printable.prefix(maxClientNameLength - 1)) + "…" : printable
}

// A universal app's default slice can differ from the one this Mac runs, and Apple's apps have no team id,
// so their signer would not match the running process's. arm64e is what they run on Apple silicon.
private func staticCodeAsItRuns(at path: String) -> SecStaticCode? {
  let url = URL(fileURLWithPath: path) as CFURL
  var code: SecStaticCode?
  #if arch(arm64)
  let slice = [kSecCodeAttributeArchitecture: NSNumber(value: CPU_TYPE_ARM64), kSecCodeAttributeSubarchitecture: NSNumber(value: CPU_SUBTYPE_ARM64E)] as CFDictionary
  if SecStaticCodeCreateWithPathAndAttributes(url, [], slice, &code) == errSecSuccess, let code { return code }
  #endif
  return SecStaticCodeCreateWithPath(url, [], &code) == errSecSuccess ? code : nil
}

private func validStaticCode(of app: AppIdentity) -> SecStaticCode? {
  var staticCode: SecStaticCode?
  if app.pid > 0 {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid: NSNumber(value: app.pid)] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
      SecCodeCheckValidity(code, [], nil) == errSecSuccess,
      SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess
    else { return nil }
    return staticCode
  }
  guard let path = app.path, let staticCode = staticCodeAsItRuns(at: path),
    SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil) == errSecSuccess
  else { return nil }
  return staticCode
}

// Code that Apple signed as part of macOS. Apple's own apps have no team id, and their code hash changes with
// every system update, so they are named by this anchor instead.
private let appleAnchor: SecRequirement? = {
  var requirement: SecRequirement?
  return SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess ? requirement : nil
}()

// List entries name who signed the app, so another app claiming the same bundle id is not covered. A signature
// that does not verify counts as none. The running process is what gets checked once there is one.
func signingIdentity(of app: AppIdentity) -> String? {
  guard let staticCode = validStaticCode(of: app) else { return nil }
  if let appleAnchor, SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSDoNotValidateResources), appleAnchor) == errSecSuccess {
    return "apple"
  }
  var information: CFDictionary?
  guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
    let details = information as? [String: Any]
  else { return nil }
  if let team = details[kSecCodeInfoTeamIdentifier as String] as? String { return "team:\(team)" }
  if let unique = details[kSecCodeInfoUnique as String] as? Data {
    return "cdhash:" + unique.map { String(format: "%02x", $0) }.joined()
  }
  return nil
}

// MARK: Permanent approvals

enum ApprovalStore {
  private static var path: String { Configuration.home + "/approvals.json" }
  private static let lock = NSLock()

  // Expired approvals count as absent, and leave the file on the next write.
  // Each entry on its own, so one malformed entry does not hide, and on the next write drop, all the others.
  private static func read() -> [[String: String]] {
    guard let data = FileManager.default.contents(atPath: path),
      let object = try? JSONSerialization.jsonObject(with: data) as? JSON,
      let entries = object["approvals"] as? [Any]
    else { return [] }
    let approvals = entries.compactMap { $0 as? [String: String] }
    let now = Date()
    return approvals.filter { entry in
      guard let text = entry["expires_at"] else { return true }
      guard let expiry = ISO8601DateFormatter().date(from: text) else { return false }
      return expiry > now
    }
  }

  private static func write(_ approvals: [[String: String]]) throws {
    let data = try JSONSerialization.data(withJSONObject: ["approvals": approvals], options: [.prettyPrinted, .sortedKeys])
    let temporary = path + ".\(getpid())"
    guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw HelperError(code: "store_failed", message: "Could not write \(temporary).")
    }
    guard rename(temporary, path) == 0 else {
      throw HelperError(code: "store_failed", message: "Could not replace \(path).")
    }
  }

  // The signer is read only for an app on the list, because checking a signature costs more than reading the file.
  static func contains(bundleId: String, signer: @autoclosure () -> String?) -> Bool {
    let entries = lock.withLock { read().filter { $0["bundle_id"] == bundleId } }
    guard !entries.isEmpty, let signer = signer() else { return false }
    // Entries made before Apple's apps were named by the anchor hold a code hash that a system update changes;
    // the bundle id together with Apple's signature identifies the app the user chose.
    return entries.contains { $0["signer"] == signer || (signer == "apple" && $0["signer"]?.hasPrefix("cdhash:") == true) }
  }

  static func add(bundleId: String, signer: String) throws {
    try lock.withLock {
      let others = read().filter { $0["bundle_id"] != bundleId }
      try write(others + [["bundle_id": bundleId, "signer": signer]])
    }
  }

  static func list() -> [[String: String]] {
    lock.withLock { read() }
  }

  static func revoke(bundleId: String) throws -> Bool {
    try lock.withLock {
      let current = read()
      let remaining = current.filter { $0["bundle_id"] != bundleId }
      guard remaining.count != current.count else { return false }
      try write(remaining)
      return true
    }
  }
}

struct DecisionRecord: Identifiable, Equatable {
  let id: Int
  let time: Date?
  let bundleId: String
  let decision: String
  let client: String?
}

// The latest answers first, from the decision log.
func recentDecisions(limit: Int) -> [DecisionRecord] {
  guard let text = try? String(contentsOfFile: Configuration.home + "/decisions.jsonl", encoding: .utf8) else { return [] }
  let lines = text.split(separator: "\n").suffix(limit).reversed()
  return lines.enumerated().compactMap { index, line in
    guard let data = line.data(using: .utf8), let entry = try? JSONSerialization.jsonObject(with: data) as? JSON,
      let bundleId = entry["app"] as? String, let decision = entry["decision"] as? String
    else { return nil }
    return DecisionRecord(
      id: index, time: (entry["time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }, bundleId: bundleId,
      decision: decision, client: entry["client"] as? String)
  }
}

// Connections log from their own threads; one lock keeps each record whole and in place.
private let decisionLogLock = NSLock()

// Who changed the list, as the Activity tab shows it: the window, or a request to the socket such as the
// command line, which an agent with a shell can also send.
let settingsClient = "settings", commandLineClient = "command_line"

// The log keeps its newest records only: past this size, about two thousand of them, it is cut back to the newest
// thousand in one rewrite, so a write rarely costs more than an append.
private let decisionLogLimit = 200_000
private let keptDecisions = 1000

private func trimDecisionLog(at path: String) {
  guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
  let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
  let kept = lines.suffix(keptDecisions).joined(separator: "\n") + "\n"
  let staging = path + ".trim"
  guard FileManager.default.createFile(atPath: staging, contents: Data(kept.utf8), attributes: [.posixPermissions: 0o600]),
        rename(staging, path) == 0
  else {
    unlink(staging)
    return
  }
}

func writeDecisionLog(client: String?, bundleId: String, decision: String) {
  let entry: JSON = [
    "time": ISO8601DateFormatter().string(from: Date()), "client": client ?? NSNull(), "app": bundleId, "decision": decision,
  ]
  guard var data = try? JSONSerialization.data(withJSONObject: entry) else { return }
  data.append(0x0a)
  let path = Configuration.home + "/decisions.jsonl"
  decisionLogLock.lock()
  defer { decisionLogLock.unlock() }
  if !FileManager.default.fileExists(atPath: path) {
    FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
  }
  guard let handle = FileHandle(forWritingAtPath: path) else { return }
  defer { try? handle.close() }
  let size = (try? handle.seekToEnd()) ?? 0
  try? handle.write(contentsOf: data)
  if size > decisionLogLimit { trimDecisionLog(at: path) }
}

// MARK: Session state

// Outlives a connection, so a reconnecting server keeps its element numbers and reads.
final class ApprovalSession {
  let lock = NSLock()
  // Apps this session has used, so Activity records each app once per session rather than every action.
  var usedApps = Set<String>()
  let table = ElementTable()
  var lastReads: [pid_t: LastRead] = [:]
  var clientName: String?
  // Guarded by the lock of the session registry.
  var attachedConnections = 0
  var detachedAt = Date()
}

// The one way an app goes on the list: never one that is never available, and only with a valid signature, which
// the list entry names so another app claiming the same bundle id is not covered.
func addToList(_ app: AppIdentity, by client: String) throws {
  if app.bundleId.isEmpty || isNeverApproved(app.bundleId) || app.pid == getpid() {
    throw HelperError(code: "not_allowed", message: "\(app.name) is never available to agents.")
  }
  guard let signer = signingIdentity(of: app) else {
    throw HelperError(code: "not_allowed", message: "\(app.name) has no valid signature, so it cannot go on the list. Allow every app covers it.")
  }
  try ApprovalStore.add(bundleId: app.bundleId, signer: signer)
  writeDecisionLog(client: client, bundleId: app.bundleId, decision: "added")
}

// Whether agents may use an app right now. list_apps reports it, so an agent can check before any other route.
enum AppAccess: String {
  case allowed
  case notApproved = "not_approved"
  case neverAvailable = "never_available"
}

enum ApprovalGate {
  static func access(_ app: AppIdentity) -> AppAccess {
    if app.bundleId.isEmpty || isNeverApproved(app.bundleId) || app.pid == getpid() { return .neverAvailable }
    return Preferences.allowsEveryApp || ApprovalStore.contains(bundleId: app.bundleId, signer: signingIdentity(of: app))
      ? .allowed : .notApproved
  }

  // The messages speak to the agent at the moment it might look for another way, so they name the app exactly
  // (the bundle id, since a display name is the app's own text) and say what to do instead.
  static func require(_ app: AppIdentity, session: ApprovalSession) throws {
    let id = app.bundleId.isEmpty ? "no bundle id" : app.bundleId
    let name = readableAppName(app.name) ?? id
    switch access(app) {
    case .neverAvailable:
      throw HelperError(
        code: "not_allowed", message: "\(name) (\(id)) is never available to agents, by any route. Do not try another way.")
    case .notApproved:
      throw HelperError(
        code: "not_approved",
        message: "\(name) (\(id)) is not on the user's list of apps agents may use. Do not use it another way (scripting, Shortcuts, computer use, another app, its data in ~/Library) and do not change the list; a chat request does not change access. Tell the user to add \(name) on the Apps tab in Backstage, or turn on Allow every app there, and continue with work that does not need it.")
    case .allowed:
      break
    }
    let (firstUse, client) = session.lock.withLock { (session.usedApps.insert(app.bundleId).inserted, session.clientName) }
    if firstUse { writeDecisionLog(client: client, bundleId: app.bundleId, decision: "used") }
  }
}
