// The General tab: starting at login, the menu bar item, and the version.

import SwiftUI

struct GeneralTab: View {
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
    ListSection(heading: ControlTexts.background) {
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
    }
    Text(ControlTexts.keepsRunning).font(.system(size: 11)).foregroundStyle(Palette.secondary)
    Text(ControlTexts.version(Configuration.appName, Configuration.buildVersion))
      .font(.system(size: 11)).foregroundStyle(Palette.secondary)
      .padding(.top, 10)
  }
}
