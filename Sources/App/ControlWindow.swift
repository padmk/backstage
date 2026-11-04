// The window people open themselves: what macOS has granted, which apps may be controlled and for how long,
// and what was decided recently. Double-clicking the app shows it.

import AppKit
import SwiftUI

private struct ControlTexts {
  let permissions, accessibility, screenRecording, granted, missing, openSettings, restart, restartHint: String
  let appAccess, appAccessHint, allowAll, notAsked, denied, checkedWhenRunning, asking: String
  let apps, none, add, always, oneHour, oneDay, oneWeek, session, remove, until, cannotAdd, saveFailed, recent, nothingRecent, farReaching: String
}

private let englishTexts = ControlTexts(
  permissions: "macOS Permissions", accessibility: "Accessibility", screenRecording: "Screen Recording",
  granted: "Granted", missing: "Missing", openSettings: "Open Settings…", restart: "Restart",
  restartHint: "A new Screen Recording grant applies after a restart, which ends session approvals.",
  appAccess: "App Access",
  appAccessHint: "Allow these once, so ready operations do not stop to ask in the middle of a task. Agents still need your approval for each app.",
  allowAll: "Allow All…", notAsked: "Not asked", denied: "Off in System Settings", checkedWhenRunning: "Shown once the app runs", asking: "Waiting for your answer…",
  apps: "Apps Agents May Control", none: "No approved apps. An agent asks the first time it needs one.", add: "Add App…",
  always: "Always", oneHour: "For 1 Hour", oneDay: "For 1 Day", oneWeek: "For 1 Week", session: "This session",
  remove: "Remove", until: "Until", cannotAdd: "This app cannot be approved here.", saveFailed: "The change could not be saved.", recent: "Recent Decisions",
  nothingRecent: "Nothing yet.", farReaching: "Can run commands or change your system.")

private let controlTexts = englishTexts

private struct AppRow: Identifiable, Equatable {
  enum Duration: Equatable {
    case always, until(Date), session
  }
  let bundleId: String
  let signer: String?
  let duration: Duration
  var id: String { bundleId }
  var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) }
  var name: String { url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleId }
}

private enum ApprovalLength: String {
  case always, hour, day, week

  var seconds: TimeInterval? {
    switch self {
    case .always: return nil
    case .hour: return 3600
    case .day: return 86400
    case .week: return 604800
    }
  }
}

private final class ControlModel: ObservableObject {
  @Published var accessibility = false
  @Published var screenRecording = false
  @Published var rows: [AppRow] = []
  @Published var recent: [String] = []
  @Published var grants: [String: GrantState] = [:]
  @Published var asking: Set<String> = []
  @Published var problem: String?
  private var timer: Timer?

  init() {
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
  }

  deinit { timer?.invalidate() }

  func refresh() {
    let trusted = AXIsProcessTrusted()
    if trusted != accessibility { accessibility = trusted }
    let recording = CGPreflightScreenCaptureAccess()
    if recording != screenRecording { screenRecording = recording }
    let stored = ApprovalStore.list().compactMap { entry -> AppRow? in
      guard let bundleId = entry["bundle_id"] else { return nil }
      let until = entry["expires_at"].flatMap { ISO8601DateFormatter().date(from: $0) }
      return AppRow(bundleId: bundleId, signer: entry["signer"], duration: until.map { .until($0) } ?? .always)
    }
    let inSession = sessionApprovals().filter { approval in !stored.contains { $0.bundleId == approval.bundleId } }
      .map { AppRow(bundleId: $0.bundleId, signer: $0.signer, duration: .session) }
    let all = (stored + inSession).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    if all != rows { rows = all }
    let latest = recentDecisions(limit: 15)
    if latest != recent { recent = latest }
    let states = Dictionary(uniqueKeysWithValues: appGrants.map { ($0.id, grantState($0)) })
    if states != grants { grants = states }
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
  func canKeep(_ row: AppRow) -> Bool {
    row.signer != nil
  }

  func set(_ row: AppRow, to choice: ApprovalLength) {
    guard let signer = row.signer else { return }
    do {
      try ApprovalStore.add(bundleId: row.bundleId, signer: signer, until: choice.seconds.map { Date().addingTimeInterval($0) })
      revokeSessionApprovals(bundleId: row.bundleId)
      writeDecisionLog(client: "settings", bundleId: row.bundleId, decision: choice.rawValue)
      problem = nil
    } catch {
      problem = controlTexts.saveFailed
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
      problem = controlTexts.saveFailed
    }
    refresh()
  }

  func add(_ url: URL) {
    guard let app = identity(ofAppAt: url), !isNeverApproved(app.bundleId), let signer = signingIdentity(of: app) else {
      problem = controlTexts.cannotAdd
      return
    }
    do {
      try ApprovalStore.add(bundleId: app.bundleId, signer: signer, until: nil)
      writeDecisionLog(client: "settings", bundleId: app.bundleId, decision: ApprovalLength.always.rawValue)
      problem = nil
    } catch {
      problem = controlTexts.saveFailed
    }
    refresh()
  }
}

private func identity(ofAppAt url: URL) -> AppIdentity? {
  guard let bundleId = Bundle(url: url)?.bundleIdentifier else { return nil }
  return AppIdentity(pid: 0, bundleId: bundleId, name: url.deletingPathExtension().lastPathComponent, launchDate: nil, path: url.path)
}

private struct PermissionRow: View {
  let name: String
  let isGranted: Bool
  let pane: String

  var body: some View {
    HStack {
      Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(isGranted ? .green : .orange)
        .accessibilityHidden(true)
      Text(name)
      Spacer()
      Text(isGranted ? controlTexts.granted : controlTexts.missing).foregroundStyle(.secondary)
      Button(controlTexts.openSettings) { openPrivacyPane(pane) }
    }
  }
}

private func openPrivacyPane(_ pane: String) {
  if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
}

// A switch per grant. Turning one on asks macOS; once macOS has an answer, only System Settings can change it,
// so the switch opens the right pane there.
private struct GrantRow: View {
  let grant: AppGrant
  @ObservedObject var model: ControlModel

  private var state: GrantState { model.grants[grant.id] ?? .unknown }

  private var status: String? {
    if model.asking.contains(grant.id) { return controlTexts.asking }
    switch state {
    case .granted: return nil
    case .notAsked: return controlTexts.notAsked
    case .denied: return controlTexts.denied
    case .unknown: return controlTexts.checkedWhenRunning
    }
  }

  var body: some View {
    Toggle(isOn: Binding(
      get: { state == .granted },
      set: { on in
        if on, state == .notAsked || state == .unknown { model.request([grant]) } else { openPrivacyPane(grant.pane) }
      }
    )) {
      VStack(alignment: .leading) {
        Text(grant.name)
        Text([grant.purpose, status].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
      }
    }
    .disabled(model.asking.contains(grant.id))
  }
}

private struct ControlView: View {
  @StateObject private var model = ControlModel()

  private func describe(_ duration: AppRow.Duration) -> String {
    switch duration {
    case .always: return controlTexts.always
    case .session: return controlTexts.session
    case .until(let date): return "\(controlTexts.until) \(date.formatted(date: .abbreviated, time: .shortened))"
    }
  }

  private func addApp() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.add(url)
  }

  var body: some View {
    Form {
      Section(controlTexts.permissions) {
        PermissionRow(name: controlTexts.accessibility, isGranted: model.accessibility, pane: "Privacy_Accessibility")
        PermissionRow(name: controlTexts.screenRecording, isGranted: model.screenRecording, pane: "Privacy_ScreenCapture")
        if !model.screenRecording {
          HStack {
            Text(controlTexts.restartHint).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(controlTexts.restart, action: restartApp)
          }
        }
      }
      Section {
        ForEach(appGrants) { GrantRow(grant: $0, model: model) }
      } header: {
        HStack {
          Text(controlTexts.appAccess)
          Spacer()
          Button(controlTexts.allowAll) {
            model.request(appGrants.filter { model.grants[$0.id] != .granted && model.grants[$0.id] != .denied })
          }
          .disabled(!appGrants.contains { model.grants[$0.id] == .notAsked || model.grants[$0.id] == .unknown })
        }
      } footer: {
        Text(controlTexts.appAccessHint).font(.caption).foregroundStyle(.secondary)
      }
      Section(controlTexts.apps) {
        if model.rows.isEmpty {
          Text(controlTexts.none).foregroundStyle(.secondary)
        }
        ForEach(model.rows) { row in
          HStack {
            if let url = row.url {
              Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24).accessibilityHidden(true)
            }
            VStack(alignment: .leading) {
              Text(row.name)
              if isFarReaching(row.bundleId) {
                Text(controlTexts.farReaching).font(.caption).foregroundStyle(.secondary)
              }
            }
            Spacer()
            Menu(describe(row.duration)) {
              if model.canKeep(row) {
                Button(controlTexts.always) { model.set(row, to: .always) }
                Button(controlTexts.oneHour) { model.set(row, to: .hour) }
                Button(controlTexts.oneDay) { model.set(row, to: .day) }
                Button(controlTexts.oneWeek) { model.set(row, to: .week) }
                Divider()
              }
              Button(controlTexts.remove, role: .destructive) { model.remove(row) }
            }
            .fixedSize()
          }
        }
        HStack {
          Button(controlTexts.add, action: addApp)
          if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
        }
      }
      Section(controlTexts.recent) {
        if model.recent.isEmpty { Text(controlTexts.nothingRecent).foregroundStyle(.secondary) }
        ForEach(Array(model.recent.enumerated()), id: \.offset) { _, line in
          Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 600, height: 760)
  }
}

// After a restart the user asked for, the window opens again in front, in the process that replaces this one.
// A restart they did not ask for, such as after an update, leaves the window closed: bringing it back would
// open the app a second time, which macOS treats as the user reopening it and brings to the front.
private func scheduleReopen() {
  let script = Process()
  script.executableURL = URL(fileURLWithPath: "/bin/sh")
  script.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
  try? script.run()
}

private func restartApp() {
  scheduleReopen()
  unlink(Configuration.socketPath)
  exit(0)
}

private final class ControlWindowCloser: NSObject, NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    // Back to having no Dock icon, as the background helper it also is.
    DispatchQueue.main.async {
      controlWindow = nil
      NSApp.setActivationPolicy(.accessory)
    }
  }
}

private let closer = ControlWindowCloser()
private var controlWindow: NSWindow?

var isControlWindowOpen: Bool { onMain { controlWindow != nil } }

// Standard keys for a window with a Dock icon. Quitting closes the window, because the app also serves agents.
private func controlMenu() -> NSMenu {
  let bar = NSMenu()
  let appItem = NSMenuItem()
  let appMenu = NSMenu()
  appMenu.addItem(withTitle: "Quit", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "q")
  appMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
  appItem.submenu = appMenu
  bar.addItem(appItem)
  let editItem = NSMenuItem()
  let editMenu = NSMenu(title: "Edit")
  editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
  editItem.submenu = editMenu
  bar.addItem(editItem)
  return bar
}

func showControlWindow() {
  NSApp.setActivationPolicy(.regular)
  NSApp.mainMenu = controlMenu()
  if controlWindow == nil {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 760), styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered, defer: false)
    window.title = Configuration.appName
    window.isReleasedWhenClosed = false
    window.delegate = closer
    window.contentView = NSHostingView(rootView: ControlView())
    window.center()
    controlWindow = window
  }
  controlWindow?.makeKeyAndOrderFront(nil)
  // The one place this app comes forward, because the user opened it.
  NSApp.activate(ignoringOtherApps: true)
}
