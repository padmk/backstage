// The Setup tab: how Backstage runs in the background, what macOS has granted it, and the grants that the listed
// apps' ready operations use.

import AppKit
import SwiftUI

private struct Allowed: View {
  var body: some View {
    Label(ControlTexts.allowed, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.sky)
  }
}

// One of Backstage's own optional permissions. Off is not a problem, so it shows only what it is for and Allow;
// once the user is in System Settings for it, the row says what to turn on there.
private struct PermissionRow: View {
  let permission: SystemPermission
  @ObservedObject var model: ControlModel

  var body: some View {
    let opened = model.inSettings.contains(permission.rawValue)
    ControlRow(icon: .symbol(permissionSymbol(permission)), title: permission.name,
               detail: opened ? ControlTexts.turnOnInSettings : permission.purpose,
               detailColor: opened ? Palette.sky : Palette.secondary) {
      if model.state(of: permission) == .granted {
        Allowed()
      } else if model.prompting.contains(permission) {
        Text(ControlTexts.waitingForMacOS).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
      } else {
        Button(opened ? ControlTexts.openSettings : ControlTexts.allow) {
            if opened { model.openSettings(for: permission) } else { model.allow(permission) }
          }.buttonStyle(ChoiceStyle(kind: .plain, compact: true))
      }
    }
  }
}

// macOS shows no prompt for another app's data, so the row leads to Full Disk Access, with a panel to drag
// Backstage from into the list there.
private struct AppDataAccess: View {
  let grant: AppGrant
  @ObservedObject var model: ControlModel

  var body: some View {
    Button(ControlTexts.addInSettings) {
      model.request([grant])
      showDragIntoSettings(for: grant)
    }.buttonStyle(ChoiceStyle(kind: .primary, compact: true))
  }
}

// Asking macOS is the only thing this row can do: once macOS has an answer, only System Settings changes it.
private struct GrantRow: View {
  let grant: AppGrant
  @ObservedObject var model: ControlModel

  var body: some View {
    let state = model.grants[grant.id] ?? .unknown
    let isAppData = if case .appData = grant.kind { true } else { false }
    let opened = model.inSettings.contains(grant.id) && state != .granted
    let detail = opened && !isAppData ? ControlTexts.turnOnInSettings
      : isAppData && state != .granted ? "\(grant.purpose) · \(ControlTexts.needsFullDiskAccess)"
      : state == .unknown ? "\(grant.purpose) · \(ControlTexts.unknownUntilOpen)" : grant.purpose
    ControlRow(icon: .app(grant.appBundleId), title: grant.name, detail: detail, detailColor: opened && !isAppData ? Palette.sky : Palette.secondary) {
      if isAppData, state != .granted {
        AppDataAccess(grant: grant, model: model)
      } else if model.asking.contains(grant.id) {
        Text(ControlTexts.asking).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
      } else {
        switch state {
        case .granted: Allowed()
        case .denied:
          Button(ControlTexts.allow) { model.allowInSettings(grant) }.buttonStyle(ChoiceStyle(kind: .plain, compact: true))
        case .notAsked, .unknown:
          Button(ControlTexts.allow) { model.request([grant]) }.buttonStyle(ChoiceStyle(kind: .plain, compact: true))
        }
      }
    }
  }
}

struct SetupTab: View {
  @ObservedObject var model: ControlModel

  private var loginDetail: (String, Color) {
    if let problem = model.loginProblem { return (problem, Palette.coral) }
    switch model.login {
    case .needsApproval: return (ControlTexts.loginNeedsApproval, Palette.amber)
    case .unavailable: return (ControlTexts.loginUnavailable, Palette.secondary)
    case .on, .off: return (ControlTexts.openAtLoginDetail, Palette.secondary)
    }
  }

  var body: some View {
    ListSection(heading: ControlTexts.background, note: ControlTexts.keepsRunning) {
      ControlRow(icon: .symbol("power"), title: ControlTexts.openAtLogin, detail: loginDetail.0, detailColor: loginDetail.1) {
        HStack(spacing: 8) {
          if model.login == .needsApproval {
            Button(ControlTexts.openLoginItems, action: LaunchAtLogin.openLoginItems).buttonStyle(ChoiceStyle(kind: .plain, compact: true))
          }
          Toggle("", isOn: Binding(get: { model.login == .on || model.login == .needsApproval }, set: { model.setLogin($0) }))
            .labelsHidden().toggleStyle(.switch).tint(Palette.sky)
            .disabled(model.login == .unavailable)
        }
      }
      RowDivider()
      ControlRow(icon: .symbol("menubar.rectangle"), title: ControlTexts.showInMenuBar, detail: ControlTexts.showInMenuBarDetail) {
        Toggle("", isOn: Binding(get: { model.showsMenuBarItem }, set: { model.setMenuBarItem($0) }))
          .labelsHidden().toggleStyle(.switch).tint(Palette.sky)
          .disabled(!Preferences.isInstalledCopy)
      }
      RowDivider()
      ControlRow(icon: .symbol("lock.display"), title: ControlTexts.windowsWhileLocked,
                 detail: model.worksInWindowsWhileLocked ? ControlTexts.windowsWhileLockedOn : ControlTexts.windowsWhileLockedOff,
                 detailColor: model.worksInWindowsWhileLocked ? Palette.amber : Palette.secondary) {
        Toggle("", isOn: Binding(get: { model.worksInWindowsWhileLocked }, set: { model.setWindowsWhileLocked($0) }))
          .labelsHidden().toggleStyle(.switch).tint(Palette.sky)
      }
    }

    ListSection(heading: ControlTexts.macOSPermissions) {
      let accessibilityOpened = model.inSettings.contains(accessibilityId) && !model.accessibility
      ControlRow(icon: .symbol("accessibility"), title: ControlTexts.accessibility,
                 detail: model.accessibility ? ControlTexts.accessibilityPurpose : accessibilityOpened ? ControlTexts.turnOnInSettings : ControlTexts.accessibilityNeeded,
                 detailColor: model.accessibility ? Palette.secondary : accessibilityOpened ? Palette.sky : Palette.amber) {
        if model.accessibility {
          Allowed()
        } else {
          Button(ControlTexts.allow, action: model.allowAccessibility).buttonStyle(ChoiceStyle(kind: .primary, compact: true))
        }
      }
      ForEach(SystemPermission.allCases) { permission in
        RowDivider()
        PermissionRow(permission: permission, model: model)
      }
    }

    ListSection(heading: ControlTexts.appAccess, note: ControlTexts.appAccessHint) {
      let shown = model.relevantGrants
      if shown.isEmpty {
        EmptyState(symbol: "checkmark.seal", title: ControlTexts.noGrants, detail: ControlTexts.noGrantsDetail)
      }
      ForEach(Array(shown.enumerated()), id: \.element.id) { index, grant in
        if index > 0 { RowDivider() }
        GrantRow(grant: grant, model: model)
      }
    }

    Text(ControlTexts.version(Configuration.appName, "\(Configuration.version) (\(Configuration.build))"))
      .font(.system(size: 11)).foregroundStyle(Palette.secondary)
      .padding(.top, 10)
  }
}
