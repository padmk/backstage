// The Apps tab: the switch that allows every app, and otherwise the list of apps agents may use through Backstage.
// While every app is allowed the list does not apply, so it folds away; it is kept for when the switch goes off.

import AppKit
import SwiftUI

struct AppsTab: View {
  @ObservedObject var model: ControlModel
  let showSetup: () -> Void

  private func addApp() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.add(url)
  }

  var body: some View {
    ListSection(heading: ControlTexts.access, note: ControlTexts.honesty) {
      ControlRow(icon: .symbol("square.grid.2x2"), title: ControlTexts.everyApp,
                 detail: model.allowsEveryApp ? ControlTexts.everyAppOn : ControlTexts.everyAppOff,
                 detailColor: model.allowsEveryApp ? Palette.amber : Palette.secondary) {
        Toggle("", isOn: Binding(get: { model.allowsEveryApp }, set: { model.setEveryApp($0) }))
          .labelsHidden().toggleStyle(.switch).tint(Palette.sky)
      }
    }

    // The list says which apps agents may use; macOS separately guards some apps' data, on the Setup tab.
    if model.grantsWaiting {
      HStack(spacing: 8) {
        Text(ControlTexts.grantsWaiting).font(.system(size: 12)).foregroundStyle(Palette.amber)
        Button(ControlTexts.showSetup, action: showSetup).buttonStyle(ChoiceStyle(kind: .plain, compact: true))
      }
    }
    if model.allowsEveryApp {
      if !model.rows.isEmpty {
        Text(ControlTexts.listKept(model.rows.count)).font(.system(size: 11)).foregroundStyle(Palette.secondary)
      }
    } else {
      appList
    }
    if !model.computers.isEmpty {
      ListSection(heading: ControlTexts.computersHeading, note: ControlTexts.computersNote) {
        ForEach(Array(model.computers.enumerated()), id: \.element) { index, name in
          if index > 0 { RowDivider() }
          ControlRow(icon: .symbol("desktopcomputer"), title: name, detail: ControlTexts.computerDetail) {
            Button(ControlTexts.remove) { model.removeComputer(name) }.buttonStyle(ChoiceStyle(kind: .plain, compact: true))
          }
        }
      }
    }
    if let problem = model.problem {
      Text(problem).font(.system(size: 12)).foregroundStyle(Palette.coral)
    }
  }

  private var appList: some View {
    ListSection(heading: ControlTexts.appsHeading) {
      Button(ControlTexts.add, action: addApp).buttonStyle(ChoiceStyle(kind: .primary, compact: true))
    } content: {
      if model.rows.isEmpty {
        EmptyState(symbol: "app.dashed", title: ControlTexts.noApps, detail: ControlTexts.noAppsDetail)
      }
      ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
        if index > 0 { RowDivider() }
        VStack(alignment: .leading, spacing: 0) {
          ControlRow(icon: .app(row.bundleId), title: row.name, detail: row.bundleId, monospacedDetail: true) {
            Button(ControlTexts.remove) { model.remove(row) }.buttonStyle(ChoiceStyle(kind: .plain, compact: true))
          }
          if let reach = knowledge(forBundleId: row.bundleId)?.access {
            Text(reach).font(.system(size: 11)).foregroundStyle(Palette.secondary)
              .padding(.leading, rowIconSide + rowIconGap)
              .padding(.bottom, isFarReaching(row.bundleId) ? 2 : 8)
          }
          if isFarReaching(row.bundleId) {
            Label(ControlTexts.farReaching, systemImage: "exclamationmark.triangle.fill")
              .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.amber)
              .padding(.leading, rowIconSide + rowIconGap)
              .padding(.bottom, 8)
          }
        }
      }
    }
  }
}
