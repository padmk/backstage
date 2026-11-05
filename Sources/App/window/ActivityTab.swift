// The Activity tab: the latest answers to approval requests, newest first.

import SwiftUI

// Entries written before the app list existed keep a readable label.
private func chipColor(_ decision: String) -> Color {
  switch decision {
  case "decline", "removed", "every_app_on", "locked_windows_on": Palette.coral
  case "added", "every_app_off", "locked_windows_off", "hour", "day", "week", "always": Palette.sky
  default: Palette.secondary
  }
}

private func chipText(_ decision: String) -> String {
  switch decision {
  case "used": "Used"
  case "added": "Added"
  case "removed": "Removed"
  case "every_app_on": "Every app on"
  case "every_app_off": "Every app off"
  case "locked_windows_on": "On"
  case "locked_windows_off": "Off"
  case "decline": "Denied"
  case "once", "session", "hour", "day", "week", "always": "Approved"
  default: decision
  }
}

private func who(_ client: String?) -> String {
  if client == settingsClient { return ControlTexts.you }
  if client == commandLineClient { return ControlTexts.commandLine }
  return readableClientName(client) ?? ControlTexts.anAgent
}

struct ActivityTab: View {
  @ObservedObject var model: ControlModel

  var body: some View {
    ListSection(heading: ControlTexts.recentDecisions, note: ControlTexts.activityNote) {
      if model.recent.isEmpty {
        EmptyState(symbol: "clock", title: ControlTexts.noDecisions, detail: ControlTexts.noDecisionsDetail)
      }
      ForEach(Array(model.recent.enumerated()), id: \.element.id) { index, record in
        if index > 0 { RowDivider() }
        let isLockedWindows = record.decision.hasPrefix("locked_windows")
        ControlRow(icon: isLockedWindows ? .symbol("lock.display") : record.bundleId == "*" ? .symbol("square.grid.2x2") : .app(record.bundleId),
                   title: isLockedWindows ? ControlTexts.windowsWhileLocked
                     : record.bundleId == "*" ? ControlTexts.everyApp : AppRow(bundleId: record.bundleId).name,
                   detail: who(record.client)) {
          HStack(spacing: 8) {
            Text(chipText(record.decision))
              .font(.system(size: 11, weight: .semibold)).foregroundStyle(chipColor(record.decision))
              .padding(.horizontal, 7).frame(height: 18)
              .background(Capsule().fill(chipColor(record.decision).opacity(0.18)))
            if let time = record.time {
              Text(time.formatted(.relative(presentation: .named)))
                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                .frame(minWidth: 96, alignment: .trailing)
            }
          }
        }
      }
    }
  }
}
