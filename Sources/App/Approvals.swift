// The approval gate. It lives in the helper because the helper holds the macOS permissions: a process
// that reaches the socket directly meets the same gate as an agent using the MCP tools. approvals.json has
// file permissions only, so a process of this user that can write files can add a permanent approval.

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
]

// These apps can run commands or change the system, so approving one reaches far beyond it. They get a
// warning and no permanent approval.
private let farReaching: Set<String> = [
  "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
  "dev.warp.Warp-Stable", "com.github.wez.wezterm", "com.apple.ScriptEditor2", "com.apple.Automator",
  "com.apple.shortcuts", "com.apple.systempreferences", "com.apple.finder", "com.apple.dt.Xcode",
  "com.microsoft.VSCode", "dev.zed.Zed",
]

func isFarReaching(_ bundleId: String) -> Bool { farReaching.contains(bundleId) }
func isNeverApproved(_ bundleId: String) -> Bool { neverApproved.contains(bundleId) || bundleId == Bundle.main.bundleIdentifier }

private let timedApprovalSeconds: TimeInterval = 3600
private let declineMemorySeconds: TimeInterval = 60
// Shorter than what the client still has left after one full approval window.
private let approvalQueueSeconds: TimeInterval = 25
let approvalTimeoutSeconds = 170

struct ApprovalTexts {
  let title: (String) -> String
  let wants: (String) -> String
  let farReaching: String
  let updatedWhileRunning: (String) -> String
  let restartForPermanent: String
  let labels: ApprovalLabels
  let agent: String
}

private let english = ApprovalTexts(
  title: { "Allow control of \($0)?" },
  wants: { "\($0) wants to see this app's windows, click in them and type." },
  farReaching: "This app can run commands or change your system, so this reaches beyond the app itself.",
  updatedWhileRunning: { "\($0) was updated while running, so its signature cannot be confirmed. This approval lasts until it quits." },
  restartForPermanent: "Restart it to use a permanent approval.",
  labels: ApprovalLabels(
    session: "Allow for This Session", hour: "Allow for 1 Hour", always: "Always Allow", decline: "Decline",
    countdown: "Declines automatically in {seconds} s", unlocked: "Approval buttons are now available"),
  agent: "An agent")

private let polish = ApprovalTexts(
  title: { "Zezwolić na sterowanie aplikacją „\($0)”?" },
  wants: { "\($0) chce widzieć okna tej aplikacji, klikać w nich i pisać." },
  farReaching: "Ta aplikacja może uruchamiać polecenia lub zmieniać system, więc zgoda sięga dalej niż sama aplikacja.",
  updatedWhileRunning: { "Aplikacja „\($0)” została zaktualizowana w trakcie działania, więc nie da się potwierdzić jej podpisu. Ta zgoda obowiązuje do jej zamknięcia." },
  restartForPermanent: "Uruchom ją ponownie, aby korzystać ze stałej zgody.",
  labels: ApprovalLabels(
    session: "Zezwól na tę sesję", hour: "Zezwól na godzinę", always: "Zezwalaj zawsze", decline: "Odmów",
    countdown: "Automatyczna odmowa za {seconds} s", unlocked: "Przyciski zgody są już dostępne"),
  agent: "Agent")

private func texts(language: String?) -> ApprovalTexts {
  let preferred = language ?? Locale.preferredLanguages.first ?? "en"
  return preferred.lowercased().hasPrefix("pl") ? polish : english
}

func readableClientName(_ name: String?) -> String? {
  let words = (name ?? "").split(whereSeparator: { "-_ ".contains($0) })
  guard !words.isEmpty else { return nil }
  return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
}

// errSecCSStaticCodeChanged: the running code no longer matches the file on disk.
private let codeChangedOnDisk: OSStatus = -67034

private func wasUpdatedWhileRunning(_ app: AppIdentity) -> Bool {
  guard app.pid > 0 else { return false }
  var code: SecCode?
  let attributes = [kSecGuestAttributePid: NSNumber(value: app.pid)] as CFDictionary
  guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
  return SecCodeCheckValidity(code, [], nil) == codeChangedOnDisk
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

// Approvals name who signed the app, so another app claiming the same bundle id is asked for. A signature
// that does not verify counts as none. The running process is what gets checked once there is one.
func signingIdentity(of app: AppIdentity) -> String? {
  guard let staticCode = validStaticCode(of: app) else { return nil }
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
  private static func read() -> [[String: String]] {
    guard let data = FileManager.default.contents(atPath: path),
      let object = try? JSONSerialization.jsonObject(with: data) as? JSON,
      let approvals = object["approvals"] as? [[String: String]]
    else { return [] }
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

  static func contains(bundleId: String, signer: String?) -> Bool {
    guard let signer else { return false }
    return lock.withLock { read().contains { $0["bundle_id"] == bundleId && $0["signer"] == signer } }
  }

  static func add(bundleId: String, signer: String, until: Date?) throws {
    try lock.withLock {
      let others = read().filter { $0["bundle_id"] != bundleId }
      var entry = ["bundle_id": bundleId, "signer": signer]
      if let until { entry["expires_at"] = ISO8601DateFormatter().string(from: until) }
      try write(others + [entry])
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

func recentDecisions(limit: Int) -> [String] {
  guard let text = try? String(contentsOfFile: Configuration.home + "/decisions.jsonl", encoding: .utf8) else { return [] }
  return text.split(separator: "\n").suffix(limit).reversed().compactMap { line in
    guard let data = line.data(using: .utf8), let entry = try? JSONSerialization.jsonObject(with: data) as? JSON else { return nil }
    let parts = [entry["time"], entry["app"], entry["decision"], entry["client"]].map { ($0 as? String) ?? "" }
    return parts.joined(separator: "  ")
  }
}

func writeDecisionLog(client: String?, bundleId: String, decision: String) {
  let entry: JSON = [
    "time": ISO8601DateFormatter().string(from: Date()), "client": client ?? NSNull(), "app": bundleId, "decision": decision,
  ]
  guard var data = try? JSONSerialization.data(withJSONObject: entry) else { return }
  data.append(0x0a)
  let path = Configuration.home + "/decisions.jsonl"
  if !FileManager.default.fileExists(atPath: path) {
    FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
  }
  guard let handle = FileHandle(forWritingAtPath: path) else { return }
  defer { try? handle.close() }
  _ = try? handle.seekToEnd()
  try? handle.write(contentsOf: data)
}

// MARK: Session state

// Outlives a connection, so a reconnecting server keeps what the user decided for its session.
final class ApprovalSession {
  let lock = NSLock()
  var approved = Set<String>()
  var declinedAt: [String: Date] = [:]
  let table = ElementTable()
  var lastReads: [pid_t: LastRead] = [:]
  var clientName: String?
  var language: String?
  // Guarded by the lock of the session registry.
  var attachedConnections = 0
  var detachedAt = Date()
}

// Shows one window at a time across all sessions.
enum ApprovalGate {
  private static let oneAtATime = NSLock()

  static func require(_ app: AppIdentity, session: ApprovalSession, connection: Connection) throws {
    if app.bundleId.isEmpty {
      throw HelperError(code: "not_allowed", message: "\(app.name) has no bundle identifier, so it cannot be approved.")
    }
    if neverApproved.contains(app.bundleId) || app.bundleId == Bundle.main.bundleIdentifier || app.pid == getpid() {
      throw HelperError(code: "not_allowed", message: "\(app.name) is never available to agents.")
    }
    let appSigner = signingIdentity(of: app)
    // Without a signature the approval holds only for this process.
    let sessionKey = "\(app.bundleId)|\(appSigner ?? "pid:\(app.pid):\(app.launchDate?.timeIntervalSince1970 ?? 0)")"
    let isFarReaching = farReaching.contains(app.bundleId)
    let isApproved = {
      session.lock.withLock { session.approved.contains(sessionKey) }
        || (!isFarReaching && ApprovalStore.contains(bundleId: app.bundleId, signer: appSigner))
    }
    if isApproved() { return }

    if let declined = session.lock.withLock({ session.declinedAt[app.bundleId] }),
      Date().timeIntervalSince(declined) < declineMemorySeconds {
      throw HelperError(code: "declined", message: "The user declined \(app.name) moments ago. Do not ask again unless they tell you to.")
    }

    let queuedUntil = Date().addingTimeInterval(approvalQueueSeconds)
    while !oneAtATime.lock(before: Date().addingTimeInterval(0.2)) {
      try connection.throwIfCancelled()
      if Date() > queuedUntil {
        throw HelperError(code: "approval_busy", message: "Another approval window is waiting for the user. Try again shortly.")
      }
    }
    defer { oneAtATime.unlock() }
    try connection.throwIfCancelled()
    // Another request may have been answered while this one waited.
    if isApproved() { return }

    let language = session.lock.withLock { session.language }
    let clientName = session.lock.withLock { session.clientName }
    let chosen = texts(language: language)
    var warning = isFarReaching ? [chosen.farReaching] : []
    if wasUpdatedWhileRunning(app) {
      warning.append(chosen.updatedWhileRunning(app.name))
      if !isFarReaching { warning.append(chosen.restartForPermanent) }
    }
    let request = ApprovalRequest(
      title: chosen.title(app.name),
      // The bundle id and location tell the real app from another one using its name.
      message: chosen.wants(readableClientName(clientName) ?? chosen.agent) + "\n\n\(app.bundleId)\n\(app.path ?? "")",
      warning: warning.isEmpty ? nil : warning.joined(separator: " "),
      bundleIdentifier: app.bundleId,
      brandName: Configuration.appName,
      offersAlways: !isFarReaching && appSigner != nil,
      timeoutSeconds: approvalTimeoutSeconds,
      labels: chosen.labels)

    let decision = askUser(request, connection: connection)
    try connection.throwIfCancelled()
    writeDecisionLog(client: clientName, bundleId: app.bundleId, decision: decision.rawValue)

    switch decision {
    case .session:
      session.lock.withLock { _ = session.approved.insert(sessionKey) }
    case .always, .hour:
      // Kept only in the store, so revoking it reaches sessions already running.
      do {
        guard let appSigner else { throw HelperError(code: "store_failed", message: "The app has no valid signature.") }
        try ApprovalStore.add(bundleId: app.bundleId, signer: appSigner, until: decision == .hour ? Date().addingTimeInterval(timedApprovalSeconds) : nil)
      } catch {
        // A session approval has no end time, so it cannot stand in for a limited one.
        if decision == .hour {
          throw HelperError(code: "store_failed", message: "The approval for \(app.name) could not be saved.")
        }
        NSLog("\(Configuration.appName): could not save a permanent approval: \(error)")
        session.lock.withLock { _ = session.approved.insert(sessionKey) }
      }
    case .decline:
      session.lock.withLock { session.declinedAt[app.bundleId] = Date() }
      throw HelperError(code: "declined", message: "The user declined \(app.name), or did not answer in time.")
    }
  }
}
