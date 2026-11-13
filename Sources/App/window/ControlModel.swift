// What the Backstage window shows, read from the app list, the decision log, macOS and the settings,
// and the changes people make there.

import AppKit
import SwiftUI

// The name is looked up once, when the row is made, since the list sorts and redraws by it.
struct AppRow: Identifiable, Equatable {
  let bundleId: String
  let name: String
  var id: String { bundleId }

  init(bundleId: String) {
    self.bundleId = bundleId
    name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
      .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleId
  }
}

// The apps on the list, by name; shared by the window and the menu bar item.
func approvedApps() -> [AppRow] {
  ApprovalStore.list().compactMap { $0["bundle_id"].map(AppRow.init) }
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

// What the window reads each second. These calls reach tccd, LaunchServices, other apps' databases and files,
// so they run off the main thread.
private struct Reading {
  let accessibility: Bool
  let permissions: [SystemPermission: PermissionState]
  let rows: [AppRow]
  let recent: [DecisionRecord]
  let appNames: [String: String]
  let grants: [String: GrantState]
  let relevantGrants: [AppGrant]
  let login: LoginState
  let showsMenuBarItem: Bool
  let allowsEveryApp: Bool
  let worksInWindowsWhileLocked: Bool
  let computers: [String]

  init() {
    accessibility = AXIsProcessTrusted()
    permissions = Dictionary(uniqueKeysWithValues: SystemPermission.allCases.map { ($0, permissionState($0)) })
    rows = approvedApps()
    recent = recentDecisions(limit: 50)
    let names = Dictionary(rows.map { ($0.bundleId, $0.name) }, uniquingKeysWith: { first, _ in first })
    appNames = Dictionary(Set(recent.map(\.bundleId)).map { ($0, names[$0] ?? AppRow(bundleId: $0).name) }, uniquingKeysWith: { first, _ in first })
    grants = Dictionary(uniqueKeysWithValues: appGrants.map { ($0.id, grantState($0)) })
    allowsEveryApp = Preferences.allowsEveryApp
    relevantGrants = appGrants(forListed: Set(rows.map(\.bundleId)), everyApp: allowsEveryApp)
    login = LaunchAtLogin.state
    showsMenuBarItem = Preferences.showsMenuBarItem
    worksInWindowsWhileLocked = Preferences.worksInWindowsWhileLocked
    computers = ComputerList.allowed
  }
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
  // The names of the apps in recent, by bundle id.
  @Published var appNames: [String: String] = [:]
  @Published var grants: [String: GrantState] = [:]
  // The grants of apps on the list, or of every installed app while Allow every app is on.
  @Published var relevantGrants: [AppGrant] = []
  @Published var asking: Set<String> = []
  @Published var problem: String?
  @Published var login = LoginState.unavailable
  @Published var loginProblem: String?
  @Published var showsMenuBarItem = false
  @Published var allowsEveryApp = false
  @Published var worksInWindowsWhileLocked = false
  // Other Macs agents may reach with `computer`, and those asked for.
  @Published var computers: [String] = []
  @Published var computerRequests: [ComputerRequest] = []
  private let live: Bool
  private var timer: Timer?
  private let reader = DispatchQueue(label: "control-model.read", qos: .userInitiated)
  // One read at a time; a refresh asked for meanwhile reads again when it ends, so it sees the latest change.
  private var reading = false
  private var readAgain = false

  // A live model refreshes every second; a fixed one, for rendering a state, does not read anything. The first
  // read is made at once, so the window opens with its content.
  init(live: Bool = true) {
    self.live = live
    guard live else { return }
    apply(Reading())
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
  }

  deinit { timer?.invalidate() }

  // Screen Recording is optional: only screenshots need it.
  var permissionsMissing: Bool { !accessibility }

  // Grants of apps on the list that macOS has not given, which the Apps tab points to.
  var grantsWaiting: Bool { relevantGrants.contains { [.notAsked, .denied].contains(grants[$0.id] ?? .unknown) } }

  // Called on the main thread; reads in the background and publishes there.
  func refresh() {
    guard live else { return }
    guard !reading else {
      readAgain = true
      return
    }
    reading = true
    reader.async {
      let reading = Reading()
      DispatchQueue.main.async {
        self.apply(reading)
        self.reading = false
        if self.readAgain {
          self.readAgain = false
          self.refresh()
        }
      }
    }
  }

  private func apply(_ reading: Reading) {
    let trusted = reading.accessibility
    if trusted != accessibility { accessibility = trusted }
    let current = reading.permissions
    if current != permissions { permissions = current }
    for (permission, state) in current where state == .granted { PermissionRequests.remove(permission) }
    let asked = PermissionRequests.all
    if asked != permissionRequests { permissionRequests = asked }
    if reading.grants != grants { grants = reading.grants }
    let done = inSettings.filter { id in
      if id == accessibilityId { return trusted }
      if let permission = SystemPermission(rawValue: id) { return current[permission] == .granted }
      return grants[id] == .granted
    }
    if !done.isEmpty { inSettings.subtract(done) }
    checkSettingsIfWaiting()
    if reading.rows != rows { rows = reading.rows }
    let waiting = ApprovalRequests.all
    if waiting != requests { requests = waiting }
    if reading.recent != recent { recent = reading.recent }
    if reading.appNames != appNames { appNames = reading.appNames }
    if reading.relevantGrants.map(\.id) != relevantGrants.map(\.id) || reading.relevantGrants.map(\.name) != relevantGrants.map(\.name) {
      relevantGrants = reading.relevantGrants
    }
    if reading.login != login { login = reading.login }
    if reading.showsMenuBarItem != showsMenuBarItem { showsMenuBarItem = reading.showsMenuBarItem }
    if reading.allowsEveryApp != allowsEveryApp { allowsEveryApp = reading.allowsEveryApp }
    if reading.worksInWindowsWhileLocked != worksInWindowsWhileLocked { worksInWindowsWhileLocked = reading.worksInWindowsWhileLocked }
    if reading.computers != computers { computers = reading.computers }
    let askedComputers = ComputerList.requests
    if askedComputers != computerRequests { computerRequests = askedComputers }
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
  // A request answered already, by a second click or from a row not yet redrawn, changes nothing.
  func answer(_ asked: ApprovalRequest, add: Bool) {
    guard ApprovalRequests.remove(asked.app.bundleId) else { return }
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

  // A request answered already, by a second click or from a row not yet redrawn, changes nothing.
  func answer(_ asked: ComputerRequest, add: Bool) {
    if add {
      guard ComputerList.requests.contains(asked) else { return }
      ComputerList.add(asked.name, by: settingsClient)
    } else {
      ComputerList.decline(asked.name, by: settingsClient)
    }
    refresh()
  }

  func removeComputer(_ name: String) {
    ComputerList.remove(name, by: settingsClient)
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
