// What the Backstage window shows, read from the app list, the decision log, macOS and the settings,
// and the changes people make there.

import AppKit
import SwiftUI

struct AppRow: Identifiable, Equatable {
  let bundleId: String
  var id: String { bundleId }
  var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) }
  var name: String { url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleId }
}

// The apps on the list, by name; shared by the window and the menu bar item.
func approvedApps() -> [AppRow] {
  ApprovalStore.list().compactMap { $0["bundle_id"].map(AppRow.init) }
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

let accessibilityId = "accessibility"

final class ControlModel: ObservableObject {
  @Published var accessibility = false
  // What macOS answers this process, which is what agents get.
  @Published var permissions: [SystemPermission: PermissionState] = [:]
  @Published var permissionRequests: [PermissionRequest] = []
  // Permissions and grants the user was sent to System Settings for, which their rows explain until they are on.
  @Published var inSettings: Set<String> = []
  // Permissions whose macOS prompt is up.
  @Published var prompting: Set<SystemPermission> = []
  private var lastSettingsCheck = Date.distantPast
  private var checkingSettings = false
  @Published var rows: [AppRow] = []
  @Published var requests: [ApprovalRequest] = []
  @Published var recent: [DecisionRecord] = []
  @Published var grants: [String: GrantState] = [:]
  @Published var asking: Set<String> = []
  @Published var problem: String?
  @Published var login = LoginState.unavailable
  @Published var loginProblem: String?
  @Published var showsMenuBarItem = false
  @Published var allowsEveryApp = false
  @Published var worksInWindowsWhileLocked = false
  private var timer: Timer?

  // A live model refreshes every second; a fixed one, for rendering a state, does not read anything.
  init(live: Bool = true) {
    guard live else { return }
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
  }

  deinit { timer?.invalidate() }

  // Screen Recording is optional: only screenshots need it.
  var permissionsMissing: Bool { !accessibility }

  var relevantGrants: [AppGrant] { appGrants(forListed: Set(rows.map(\.bundleId)), everyApp: allowsEveryApp) }

  // Grants of apps on the list that macOS has not given, which the Apps tab points to.
  var grantsWaiting: Bool { relevantGrants.contains { [.notAsked, .denied].contains(grants[$0.id] ?? .unknown) } }

  func refresh() {
    let trusted = AXIsProcessTrusted()
    if trusted != accessibility { accessibility = trusted }
    let current = Dictionary(uniqueKeysWithValues: SystemPermission.allCases.map { ($0, permissionState($0)) })
    if current != permissions { permissions = current }
    for (permission, state) in current where state == .granted { PermissionRequests.remove(permission) }
    let asked = PermissionRequests.all
    if asked != permissionRequests { permissionRequests = asked }
    let done = inSettings.filter { id in
      if id == accessibilityId { return trusted }
      if let permission = SystemPermission(rawValue: id) { return current[permission] == .granted }
      return grants[id] == .granted
    }
    if !done.isEmpty { inSettings.subtract(done) }
    checkSettingsIfWaiting()
    let all = approvedApps()
    if all != rows { rows = all }
    let waiting = ApprovalRequests.all
    if waiting != requests { requests = waiting }
    let latest = recentDecisions(limit: 50)
    if latest != recent { recent = latest }
    let states = Dictionary(uniqueKeysWithValues: appGrants.map { ($0.id, grantState($0)) })
    if states != grants { grants = states }
    let loginState = LaunchAtLogin.state
    if loginState != login { login = loginState }
    let menuBar = Preferences.showsMenuBarItem
    if menuBar != showsMenuBarItem { showsMenuBarItem = menuBar }
    let everyApp = Preferences.allowsEveryApp
    if everyApp != allowsEveryApp { allowsEveryApp = everyApp }
    let lockedWindows = Preferences.worksInWindowsWhileLocked
    if lockedWindows != worksInWindowsWhileLocked { worksInWindowsWhileLocked = lockedWindows }
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

  func state(of permission: SystemPermission) -> PermissionState { permissions[permission] ?? .unknown }

  // The user chose Allow for one of Backstage's own permissions: macOS's prompt, or its pane in System Settings.
  // When the prompt ends without the grant, or macOS shows none, the row says what to turn on in System Settings
  // and offers to open it, so Allow never leaves the user without a next step. The answer is still watched.
  func allow(_ permission: SystemPermission) {
    prompting.insert(permission)
    askForPermission(permission) { [weak self] granted in
      guard let self else { return }
      self.prompting.remove(permission)
      if !granted { self.inSettings.insert(permission.rawValue) }
      self.refresh()
    }
  }

  func openSettings(for permission: SystemPermission) {
    openPrivacyPane(permission.pane)
    inSettings.insert(permission.rawValue)
  }

  func notNow(_ request: PermissionRequest) {
    PermissionRequests.remove(request.permission)
    refresh()
  }

  func allowAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(options) {
      openPrivacyPane("Privacy_Accessibility")
      inSettings.insert(accessibilityId)
    }
  }

  // A grant macOS has already answered changes only in System Settings.
  func allowInSettings(_ grant: AppGrant) {
    openPrivacyPane(grant.pane)
    inSettings.insert(grant.id)
  }

  // A permission turned on in System Settings reaches this process only after a restart, so while the user is there
  // a new process reads the answer every few seconds, and the app restarts once it is on.
  private func checkSettingsIfWaiting() {
    let waiting = SystemPermission.allCases.filter { inSettings.contains($0.rawValue) && permissions[$0] != .granted }
    guard !waiting.isEmpty, !checkingSettings, Date().timeIntervalSince(lastSettingsCheck) >= 2 else { return }
    checkingSettings = true
    lastSettingsCheck = Date()
    DispatchQueue.global().async {
      let now = permissionStatesNow()
      DispatchQueue.main.async {
        self.checkingSettings = false
        if waiting.contains(where: { now?[$0] == .granted }) { restartWhenIdleForNewGrant() }
      }
    }
  }

  func remove(_ row: AppRow) {
    do {
      if try ApprovalStore.revoke(bundleId: row.bundleId) {
        writeDecisionLog(client: settingsClient, bundleId: row.bundleId, decision: "removed")
      }
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
    do {
      try addToList(AppIdentity(pid: 0, bundleId: bundleId, name: url.deletingPathExtension().lastPathComponent, launchDate: nil, path: url.path), by: settingsClient)
      problem = nil
      // The user is here now, so macOS asks now for what the app's operations need, not in the middle of a task.
      request(appGrants.filter { $0.asksWhenAdded && $0.listedApps.contains(bundleId) && [.notAsked, .unknown].contains(grantState($0)) })
    } catch {
      problem = (error as? HelperError)?.message ?? ControlTexts.saveFailed
    }
    refresh()
  }

  // The user's answer to a request that came over the socket.
  func answer(_ asked: ApprovalRequest, add: Bool) {
    ApprovalRequests.remove(asked.app.bundleId)
    if add {
      do {
        try addToList(asked.app, by: settingsClient)
        problem = nil
        request(appGrants.filter { $0.asksWhenAdded && $0.listedApps.contains(asked.app.bundleId) && [.notAsked, .unknown].contains(grantState($0)) })
      } catch {
        problem = (error as? HelperError)?.message ?? ControlTexts.saveFailed
      }
    } else {
      writeDecisionLog(client: settingsClient, bundleId: asked.app.bundleId, decision: "decline")
    }
    refresh()
  }

  func setEveryApp(_ on: Bool) {
    Preferences.allowsEveryApp = on
    writeDecisionLog(client: settingsClient, bundleId: "*", decision: on ? "every_app_on" : "every_app_off")
    refresh()
  }

  // Turning it on reaches past a protection macOS applies on purpose, so the user confirms that once each time.
  func setWindowsWhileLocked(_ on: Bool) {
    if on {
      let alert = NSAlert()
      alert.messageText = ControlTexts.windowsWhileLockedConfirmTitle
      alert.informativeText = ControlTexts.windowsWhileLockedConfirmDetail
      alert.addButton(withTitle: ControlTexts.windowsWhileLockedConfirm)
      alert.addButton(withTitle: ControlTexts.cancel)
      guard alert.runModal() == .alertFirstButtonReturn else {
        refresh()
        return
      }
    }
    Preferences.worksInWindowsWhileLocked = on
    writeDecisionLog(client: settingsClient, bundleId: "*", decision: on ? "locked_windows_on" : "locked_windows_off")
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
