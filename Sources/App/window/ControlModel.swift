// What the Backstage window shows, read from the approval store, the decision log, macOS and the settings,
// and the changes people make there.

import AppKit
import SwiftUI

struct AppRow: Identifiable, Equatable {
  enum Duration: Equatable {
    case always, until(Date), session
  }
  let bundleId: String
  let signer: String?
  let duration: Duration
  var id: String { bundleId }
  var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) }
  var name: String { url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleId }

  var durationText: String {
    switch duration {
    case .always: ControlTexts.always
    case .session: ControlTexts.session
    case .until(let date): ControlTexts.until(shortExpiry(date))
    }
  }

  var isStored: Bool { duration != .session }
}

// A time today, a weekday and time within the week, otherwise the date, in the user's locale.
private func shortExpiry(_ date: Date) -> String {
  let calendar = Calendar.current
  if calendar.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
  if date.timeIntervalSinceNow < 6 * 86400 { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
  return date.formatted(.dateTime.day().month(.abbreviated))
}

enum ApprovalLength: String {
  case always, hour, day, week

  var seconds: TimeInterval? {
    switch self {
    case .always: nil
    case .hour: 3600
    case .day: 86400
    case .week: 604800
    }
  }
}

// The approved apps, stored and for running sessions, by name; shared by the window and the menu bar item.
func approvedApps() -> [AppRow] {
  let stored = ApprovalStore.list().compactMap { entry -> AppRow? in
    guard let bundleId = entry["bundle_id"] else { return nil }
    let until = entry["expires_at"].flatMap { ISO8601DateFormatter().date(from: $0) }
    return AppRow(bundleId: bundleId, signer: entry["signer"], duration: until.map { .until($0) } ?? .always)
  }
  let inSession = sessionApprovals().filter { approval in !stored.contains { $0.bundleId == approval.bundleId } }
    .map { AppRow(bundleId: $0.bundleId, signer: $0.signer, duration: .session) }
  return (stored + inSession).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

final class ControlModel: ObservableObject {
  @Published var accessibility = false
  @Published var screenRecording = false
  @Published var rows: [AppRow] = []
  @Published var recent: [DecisionRecord] = []
  @Published var grants: [String: GrantState] = [:]
  @Published var asking: Set<String> = []
  @Published var problem: String?
  @Published var login = LoginState.unavailable
  @Published var loginProblem: String?
  @Published var showsMenuBarItem = false
  private var timer: Timer?

  // A live model refreshes every second; a fixed one, for rendering a state, does not read anything.
  init(live: Bool = true) {
    guard live else { return }
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
  }

  deinit { timer?.invalidate() }

  var permissionsMissing: Bool { !accessibility || !screenRecording }

  func refresh() {
    let trusted = AXIsProcessTrusted()
    if trusted != accessibility { accessibility = trusted }
    let recording = CGPreflightScreenCaptureAccess()
    if recording != screenRecording { screenRecording = recording }
    let all = approvedApps()
    if all != rows { rows = all }
    let latest = recentDecisions(limit: 50)
    if latest != recent { recent = latest }
    let states = Dictionary(uniqueKeysWithValues: appGrants.map { ($0.id, grantState($0)) })
    if states != grants { grants = states }
    let loginState = LaunchAtLogin.state
    if loginState != login { login = loginState }
    let menuBar = Preferences.showsMenuBarItem
    if menuBar != showsMenuBarItem { showsMenuBarItem = menuBar }
  }

  // macOS asks one prompt at a time and waits for the answer, so the requests run in turn, off the main thread.
  func request(_ chosen: [AppGrant]) {
    let pending = chosen.filter { !asking.contains($0.id) }
    asking.formUnion(pending.map(\.id))
    DispatchQueue.global().async {
      for grant in pending {
        requestGrant(grant)
        DispatchQueue.main.async {
          self.asking.remove(grant.id)
          self.refresh()
        }
      }
    }
  }

  // Only the signer the user approved can be kept longer, never another copy found under the same bundle id.
  func canKeep(_ row: AppRow) -> Bool { row.signer != nil }

  func set(_ row: AppRow, to choice: ApprovalLength) {
    guard let signer = row.signer else { return }
    do {
      try ApprovalStore.add(bundleId: row.bundleId, signer: signer, until: choice.seconds.map { Date().addingTimeInterval($0) })
      revokeSessionApprovals(bundleId: row.bundleId)
      writeDecisionLog(client: "settings", bundleId: row.bundleId, decision: choice.rawValue)
      problem = nil
    } catch {
      problem = ControlTexts.saveFailed
    }
    refresh()
  }

  func remove(_ row: AppRow) {
    do {
      _ = try ApprovalStore.revoke(bundleId: row.bundleId)
      revokeSessionApprovals(bundleId: row.bundleId)
      writeDecisionLog(client: "settings", bundleId: row.bundleId, decision: "removed")
      problem = nil
    } catch {
      problem = ControlTexts.saveFailed
    }
    refresh()
  }

  func add(_ url: URL) {
    guard let bundleId = Bundle(url: url)?.bundleIdentifier else {
      problem = ControlTexts.cannotAdd
      return
    }
    let app = AppIdentity(pid: 0, bundleId: bundleId, name: url.deletingPathExtension().lastPathComponent, launchDate: nil, path: url.path)
    guard !isNeverApproved(app.bundleId), let signer = signingIdentity(of: app) else {
      problem = ControlTexts.cannotAdd
      return
    }
    do {
      try ApprovalStore.add(bundleId: app.bundleId, signer: signer, until: nil)
      writeDecisionLog(client: "settings", bundleId: app.bundleId, decision: ApprovalLength.always.rawValue)
      problem = nil
    } catch {
      problem = ControlTexts.saveFailed
    }
    refresh()
  }

  func setLogin(_ on: Bool) {
    do {
      try LaunchAtLogin.set(on)
      loginProblem = nil
    } catch {
      loginProblem = ControlTexts.loginFailed(error.localizedDescription)
    }
    refresh()
  }

  func setMenuBarItem(_ on: Bool) {
    Preferences.showsMenuBarItem = on
    MenuBarItem.shared.update()
    refresh()
  }
}
