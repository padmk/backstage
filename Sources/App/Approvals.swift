// The app list. Agents may use an app through Backstage only when the user put it on the list in the Backstage
// window, or turned on Allow every app; nothing asks during a task. It lives in the helper, which holds the macOS
// permissions, so a process that reaches the socket directly meets the same check as an agent using the MCP
// tools. It guards against mistakes and agents limited to Backstage, not against an agent with a shell, which can
// control the Mac without Backstage or edit approvals.json, a file with file permissions only.

import AppKit
import CryptoKit
import HelperLink
import Security

struct AppIdentity {
  let pid: pid_t
  let bundleId: String
  let name: String
  let processStart: ProcessStart?
  let path: String?
}

private let neverApproved: Set<String> = [
  "com.apple.SecurityAgent", "com.apple.loginwindow", "com.apple.LocalAuthentication.UIAgent",
  "com.apple.Passwords", "com.apple.keychainaccess",
  // The Electrum wallet, whose bundle id is its bare name.
  "Electrum",
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
// Whole families too: Passwords has helpers such as its menu bar extra under its own prefix. Password managers,
// authenticators and wallets from other makers hold the same kind of secret, so no list or switch reaches them
// either; their ids are the makers' own, as Homebrew's casks record them. Bundle ids compare without case, as
// LaunchServices compares them.
private let neverApprovedPrefixes = [
  "com.apple.Passwords.", "com.apple.keychainaccess.",
  "com.1password.", "com.agilebits.", "com.bitwarden.", "org.keepassxc.", "org.keepassx.", "com.hicknhacksoftware.MacPass",
  "me.proton.pass", "in.sinew.", "com.lastpass.", "com.keepersecurity.", "com.nordsec.nordpass", "com.sibersystems.roboform",
  "app.elpass.", "com.safeincloud.", "pw.buttercup.", "net.antelle.keeweb", "com.jumpcloud.pwm.",
  "com.yubico.", "io.ente.auth",
  "com.ledger.", "com.sparrowwallet.", "io.trezor.", "ch.shiftcrypto.", "io.atomicwallet", "zksnacks.wasabiwallet",
  "io.bluewallet.", "org.bitcoin.", "org.bitcoinfoundation.",
].map { $0.lowercased() }

private let neverApprovedLowercased = Set(neverApproved.map { $0.lowercased() })

func isNeverApproved(_ bundleId: String) -> Bool {
  let id = bundleId.lowercased()
  return neverApprovedLowercased.contains(id) || neverApprovedPrefixes.contains { id.hasPrefix($0) }
    || id == Bundle.main.bundleIdentifier?.lowercased() || id == Product.bundleIdentifier.lowercased()
}

private let maxClientNameLength = 40
// Words clients use in their names that read as capitals, such as "codex-mcp-client".
private let acronyms: Set<String> = ["mcp", "cli", "ai", "api", "ide"]

private func printable(_ text: String) -> String {
  String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }))
}

private func bounded(_ text: String) -> String {
  text.count > maxClientNameLength ? String(text.prefix(maxClientNameLength - 1)) + "…" : text
}

// The client names itself, so the name is kept to one short line in the Activity list and the menu.
func readableClientName(_ name: String?) -> String? {
  let words = printable(name ?? "").split(whereSeparator: { "-_ ".contains($0) })
  guard !words.isEmpty else { return nil }
  return bounded(words.map { acronyms.contains($0.lowercased()) ? $0.uppercased() : $0.prefix(1).uppercased() + $0.dropFirst() }
    .joined(separator: " "))
}

// An app's name as one short line without control characters, for messages agents read.
func readableAppName(_ name: String) -> String? {
  let line = printable(name).trimmingCharacters(in: .whitespaces)
  return line.isEmpty ? nil : bounded(line)
}

// The name a client gives in hello, as the session keeps it: one short line, read only this far. It cannot be
// the window's or the command line's mark, or read as either in the Activity list.
func sessionClientName(_ value: Any?) -> String? {
  guard let raw = value as? String,
    let name = readableAppName(String(String.UnicodeScalarView(raw.unicodeScalars.prefix(4 * maxClientNameLength))))
  else { return nil }
  let shown = readableClientName(name)?.lowercased()
  let reserved = [settingsClient, commandLineClient].contains(name.lowercased())
    || [ControlTexts.you, ControlTexts.commandLine].contains { $0.lowercased() == shown }
  return reserved ? nil : name
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
// Unsafe only to the compiler: a SecRequirement never changes once made, and Security lets threads share one.
nonisolated(unsafe) private let appleAnchor: SecRequirement? = {
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
  if let certificates = details[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first {
    let data = SecCertificateCopyData(leaf) as Data
    return "certificate:" + Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
  }
  if let unique = details[kSecCodeInfoUnique as String] as? Data {
    return "cdhash:" + unique.map { String(format: "%02x", $0) }.joined()
  }
  return nil
}

// MARK: Permanent approvals

enum ApprovalStore {
  private static var path: String { Configuration.directories.approvalsPath }
  private static let lock = NSLock()

  // Expired approvals count as absent, and leave the file on the next write.
  // Each entry on its own, so one malformed entry does not hide, and on the next write drop, all the others.
  private static func read() -> [[String: String]] {
    guard let data = FileManager.default.contents(atPath: path),
      // An unreadable list is an empty one: nothing is allowed until the user adds apps again.
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
    try writePrivateFile(data, to: path)
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

// A record is a few hundred bytes; a longer line is not one the app wrote, and is skipped.
private let maxDecisionRecordBytes = 4096

// The latest answers first, from the end of the decision log. Lines that do not parse are skipped.
func recentDecisions(limit: Int) -> [DecisionRecord] {
  guard let handle = FileHandle(forReadingAtPath: Configuration.directories.decisionLogPath) else { return [] }
  // Closing a handle that was only read from loses nothing.
  defer { try? handle.close() }
  // A log whose size cannot be read is read from its start.
  let size = (try? handle.seekToEnd()) ?? 0
  let start = size - min(size, UInt64(limit * maxDecisionRecordBytes))
  // The Activity tab shows no records rather than part of a log it could not read.
  guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return [] }
  // Reading from the middle of the file starts inside a record.
  let lines = data.split(separator: 0x0a).dropFirst(start > 0 ? 1 : 0).filter { $0.count <= maxDecisionRecordBytes }
  return lines.suffix(limit).reversed().enumerated().compactMap { index, line in
    // A line that is no record, such as one a full disk cut short, is skipped.
    guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? JSON,
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
// command line, which an agent with a shell can also send. A client cannot name itself either (sessionClientName).
let settingsClient = "settings", commandLineClient = "command_line"

// The log keeps its newest records only: past this size it is cut back, in one rewrite, to the newest thousand
// that fit in half of it, so a write rarely costs more than an append.
let decisionLogLimit = 200_000
private let keptDecisions = 1000

private func trimDecisionLog(at path: String) {
  guard let data = FileManager.default.contents(atPath: path) else { return }
  var kept: [Data] = []
  var bytes = 0
  for line in data.split(separator: 0x0a).reversed() where line.count <= maxDecisionRecordBytes {
    guard kept.count < keptDecisions, bytes + line.count + 1 <= decisionLogLimit / 2 else { break }
    kept.append(Data(line) + [0x0a])
    bytes += line.count + 1
  }
  let staging = path + ".trim"
  guard FileManager.default.createFile(atPath: staging, contents: Data(kept.reversed().joined()), attributes: [.posixPermissions: 0o600]),
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
  let data: Data
  do {
    data = try JSONSerialization.data(withJSONObject: entry) + [0x0a]
  } catch {
    appLog.error("An activity record could not be encoded: \(error.localizedDescription, privacy: .public)")
    return
  }
  guard data.count <= maxDecisionRecordBytes else {
    appLog.error("An activity record of \(data.count) bytes is longer than a record may be, so it was not written.")
    return
  }
  let path = Configuration.directories.decisionLogPath
  decisionLogLock.lock()
  defer { decisionLogLock.unlock() }
  if !FileManager.default.fileExists(atPath: path) {
    FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
  }
  guard let handle = FileHandle(forWritingAtPath: path) else {
    appLog.error("The activity log could not be opened for writing.")
    return
  }
  // Writes are not buffered, so a failed close loses nothing the write did not already report.
  defer { try? handle.close() }
  do {
    let size = try handle.seekToEnd()
    try handle.write(contentsOf: data)
    if size > decisionLogLimit { trimDecisionLog(at: path) }
  } catch {
    appLog.error("An activity record could not be written: \(error.localizedDescription, privacy: .public)")
  }
}

// MARK: Session state

// Outlives a connection, so a reconnecting server keeps its element numbers and reads.
// Unchecked: the apps used, the reads and the client's name are read and written holding `lock`, the connection
// count and the time it fell to none holding the session registry's lock, and the element table guards itself.
final class ApprovalSession: @unchecked Sendable {
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
  guard let signer = try signerToList(app) else {
    throw HelperError(code: "not_allowed", message: "\(app.name) has no valid signature, so it cannot go on the list. Allow every app covers it.")
  }
  try ApprovalStore.add(bundleId: app.bundleId, signer: signer)
  writeDecisionLog(client: client, bundleId: app.bundleId, decision: "added")
}

// A running app is named by its process while it is still the one asked about. By the time the user answers a
// request it may have quit, and its pid gone to another process; then the bundle at its path is named, if that
// still holds the same app.
private func signerToList(_ app: AppIdentity) throws -> String? {
  if app.pid > 0 {
    let signer = signingIdentity(of: app)
    // A process that quit or changed is not the app asked about; its bundle is checked below.
    if (try? requireSameProcess(app)) != nil { return signer }
  }
  let bundleId = app.path.flatMap { NSDictionary(contentsOfFile: $0 + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String }
  guard let path = app.path, bundleId == app.bundleId else {
    throw HelperError(code: "app_not_found", message: "\(app.name) is no longer installed where it was.")
  }
  return signingIdentity(of: AppIdentity(pid: 0, bundleId: app.bundleId, name: app.name, processStart: nil, path: path))
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
