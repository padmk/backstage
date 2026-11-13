// What waits for the user's answer, above every tab: apps and other Macs asked for from the command line or by an
// agent, and permissions an agent needed. Nothing here changes until the user chooses.

import SwiftUI

struct WaitingSection: View {
  @ObservedObject var model: ControlModel

  var body: some View {
    if !model.requests.isEmpty || !model.permissionRequests.isEmpty || !model.computerRequests.isEmpty {
      ListSection(heading: ControlTexts.requestsHeading, note: ControlTexts.requestsNote) {
        ForEach(Array(model.permissionRequests.enumerated()), id: \.element.id) { index, request in
          if index > 0 { RowDivider() }
          permissionRow(request)
        }
        ForEach(Array(model.requests.enumerated()), id: \.element.id) { index, request in
          if index > 0 || !model.permissionRequests.isEmpty { RowDivider() }
          ControlRow(icon: .app(request.app.bundleId), title: readableAppName(request.app.name) ?? request.app.bundleId,
                     detail: ControlTexts.askedToUse(readableClientName(request.client) ?? ControlTexts.anAgent)) {
            HStack(spacing: 6) {
              Button(ControlTexts.decline) { model.answer(request, add: false) }.buttonStyle(ChoiceStyle(kind: .plain, compact: true))
              Button(ControlTexts.addRequested) { model.answer(request, add: true) }.buttonStyle(ChoiceStyle(kind: .primary, compact: true))
            }
          }
        }
        ForEach(Array(model.computerRequests.enumerated()), id: \.element.id) { index, request in
          if index > 0 || !model.permissionRequests.isEmpty || !model.requests.isEmpty { RowDivider() }
          ControlRow(icon: .symbol("desktopcomputer"), title: request.name,
                     detail: ControlTexts.askedToReach(readableClientName(request.client) ?? ControlTexts.anAgent)) {
            HStack(spacing: 6) {
              Button(ControlTexts.decline) { model.answer(request, add: false) }.buttonStyle(ChoiceStyle(kind: .plain, compact: true))
              Button(ControlTexts.addRequested) { model.answer(request, add: true) }.buttonStyle(ChoiceStyle(kind: .primary, compact: true))
            }
          }
        }
      }
    }
  }

  private func permissionRow(_ request: PermissionRequest) -> some View {
    let permission = request.permission
    let opened = model.inSettings.contains(permission.rawValue)
    let client = readableClientName(request.client) ?? ControlTexts.anAgent
    return ControlRow(icon: .symbol(permissionSymbol(permission)), title: permission.name,
                      detail: opened ? ControlTexts.turnOnInSettings : ControlTexts.askedFor(client, permission.purpose),
                      detailColor: opened ? Palette.sky : Palette.secondary) {
      if model.prompting.contains(permission) {
        Text(ControlTexts.waitingForMacOS).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
      } else {
        HStack(spacing: 6) {
          Button(ControlTexts.notNow) { model.notNow(request) }.buttonStyle(ChoiceStyle(kind: .plain, compact: true))
          Button(opened ? ControlTexts.openSettings : ControlTexts.allow) {
            if opened { model.openSettings(for: permission) } else { model.allow(permission) }
          }.buttonStyle(ChoiceStyle(kind: .primary, compact: true))
        }
      }
    }
  }
}

func permissionSymbol(_ permission: SystemPermission) -> String {
  switch permission {
  case .screenRecording: "record.circle"
  case .audioRecording: "waveform"
  }
}
