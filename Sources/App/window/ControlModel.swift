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

final class ControlModel: ObservableObject {
  @Published var accessibility = false
  @Published var screenRecording = false
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

  func refresh() {
    let trusted = AXIsProcessTrusted()
    if trusted != accessibility { accessibility = trusted }
    let recording = CGPreflightScreenCaptureAccess()
    if recording != screenRecording { screenRecording = recording }
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
      request(appGrants.filter { $0.listedApps.contains(bundleId) && [.notAsked, .unknown].contains(grantState($0)) })
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
        request(appGrants.filter { $0.listedApps.contains(asked.app.bundleId) && [.notAsked, .unknown].contains(grantState($0)) })
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
