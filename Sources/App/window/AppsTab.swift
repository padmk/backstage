// The Apps tab: each app agents may control, for how long, and a way to change or remove it.

import AppKit
import SwiftUI

private struct DurationMenu: View {
  @ObservedObject var model: ControlModel
  let row: AppRow

  var body: some View {
    Menu {
      if model.canKeep(row) {
        Button(ControlTexts.always) { model.set(row, to: .always) }
        Button(ControlTexts.oneHour) { model.set(row, to: .hour) }
        Button(ControlTexts.oneDay) { model.set(row, to: .day) }
        Button(ControlTexts.oneWeek) { model.set(row, to: .week) }
        Divider()
      }
      Button(ControlTexts.remove, role: .destructive) { model.remove(row) }
    } label: {
      // One Text, because the menu style would put an image first.
      Text("\(row.durationText) \(Image(systemName: "chevron.up.chevron.down"))")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Palette.text)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .padding(.horizontal, 10)
    .frame(height: 26)
    // Stored approvals reach every agent, in the color the approval window gives that group.
    .background(RoundedRectangle(cornerRadius: 8).fill(row.isStored ? Palette.sky.opacity(0.24) : Color.white.opacity(0.14)))
  }
}

struct AppsTab: View {
  @ObservedObject var model: ControlModel

  private func addApp() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.add(url)
  }

  var body: some View {
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
            DurationMenu(model: model, row: row)
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
    if let problem = model.problem {
      Text(problem).font(.system(size: 12)).foregroundStyle(Palette.coral)
    }
  }
}
