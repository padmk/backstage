// The Permissions tab: what macOS has granted Backstage, and the grants that the listed apps' ready operations use.

import AppKit
import SwiftUI

private struct Allowed: View {
  var body: some View {
    Label(ControlTexts.allowed, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.sky)
  }
}

private struct OffInSettings: View {
  let pane: String
  var label = ControlTexts.off

  var body: some View {
    HStack(spacing: 8) {
      Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.amber)
      Button(ControlTexts.openSettings) { openPrivacyPane(pane) }.buttonStyle(ChoiceStyle(kind: .plain, compact: true))
    }
  }
}

// Asking macOS is the only thing this row can do: once macOS has an answer, only System Settings changes it.
private struct GrantRow: View {
  let grant: AppGrant
  @ObservedObject var model: ControlModel

  var body: some View {
    let state = model.grants[grant.id] ?? .unknown
    ControlRow(icon: .app(grant.appBundleId), title: grant.name,
               detail: state == .unknown ? "\(grant.purpose) · \(ControlTexts.unknownUntilOpen)" : grant.purpose) {
      if model.asking.contains(grant.id) {
        Text(ControlTexts.asking).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
      } else {
        switch state {
        case .granted: Allowed()
        case .denied: OffInSettings(pane: grant.pane)
        case .notAsked, .unknown:
          Button(ControlTexts.allow) { model.request([grant]) }.buttonStyle(ChoiceStyle(kind: .plain, compact: true))
        }
      }
    }
  }
}

struct PermissionsTab: View {
  @ObservedObject var model: ControlModel

  var body: some View {
    ListSection(heading: ControlTexts.macOSPermissions) {
      ControlRow(icon: .symbol("accessibility"), title: ControlTexts.accessibility, detail: ControlTexts.accessibilityPurpose) {
        if model.accessibility { Allowed() } else { OffInSettings(pane: "Privacy_Accessibility", label: ControlTexts.missing) }
      }
      RowDivider()
      ControlRow(icon: .symbol("record.circle"), title: ControlTexts.screenRecording,
                 detail: model.screenRecording ? ControlTexts.screenRecordingPurpose : ControlTexts.screenRecordingOptional) {
        if model.screenRecording {
          Allowed()
        } else {
          HStack(spacing: 6) {
            Button(ControlTexts.openSettings) { openPrivacyPane("Privacy_ScreenCapture") }.buttonStyle(ChoiceStyle(kind: .plain, compact: true))
            Button(ControlTexts.restart, action: restartApp).buttonStyle(ChoiceStyle(kind: .primary, compact: true))
              .help(ControlTexts.restartHint)
          }
        }
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
  }
}
