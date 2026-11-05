// The Activity tab: the latest answers to approval requests, newest first.

import SwiftUI

private func chipColor(_ decision: String) -> Color {
  switch decision {
  case "decline", "removed": Palette.coral
  case "hour", "day", "week", "always": Palette.sky
  default: Palette.secondary
  }
}

private func chipText(_ decision: String) -> String {
  switch decision {
  case "decline": "Deny"
  case "once": "Once"
  case "session": ControlTexts.session
  case "hour": ControlTexts.oneHour
  case "day": ControlTexts.oneDay
  case "week": ControlTexts.oneWeek
  case "always": ControlTexts.always
  case "removed": ControlTexts.remove
  default: decision
  }
}

private func who(_ client: String?) -> String {
  if client == "settings" { return ControlTexts.you }
  return readableClientName(client) ?? ControlTexts.anAgent
}

struct ActivityTab: View {
  @ObservedObject var model: ControlModel

  var body: some View {
    ListSection(heading: ControlTexts.recentDecisions) {
      if model.recent.isEmpty {
        EmptyState(symbol: "clock", title: ControlTexts.noDecisions, detail: ControlTexts.noDecisionsDetail)
      }
      ForEach(Array(model.recent.enumerated()), id: \.element.id) { index, record in
        if index > 0 { RowDivider() }
        ControlRow(icon: .app(record.bundleId), title: AppRow(bundleId: record.bundleId, signer: nil, duration: .session).name,
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
