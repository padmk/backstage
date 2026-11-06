// A small panel beside System Settings for a grant that has no prompt, such as Full Disk Access: a large
// Backstage icon to drag into the list there. It floats above Settings and closes once the grant is given.

import AppKit
import SwiftUI

private let panelSize = CGSize(width: 300, height: 250)
private let screenMargin: CGFloat = 24
private let grantCheckSeconds = 1.0
// Long enough to find the list and drag; after that the row on the Setup tab still leads here.
private let panelLifetimeSeconds = 600.0

private struct DragIntoSettingsView: View {
  let title: String
  let close: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text).multilineTextAlignment(.center)
      Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)).resizable().frame(width: 96, height: 96)
        // A file URL, which System Settings' lists take, rather than the file's contents.
        .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
        .help(ControlTexts.dragIntoList)
      Text(ControlTexts.dragSteps).font(.system(size: 12)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
      Button(ControlTexts.done, action: close).buttonStyle(ChoiceStyle(kind: .plain, compact: true))
    }
    .padding(18)
    .frame(width: panelSize.width, height: panelSize.height)
    .background(brandGradient.ignoresSafeArea())
  }
}

// Like the control window, it ignores input the helper itself posted, so an agent cannot drive it.
private final class OwnInputIgnoringPanel: NSPanel {
  override func sendEvent(_ event: NSEvent) {
    if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return }
    super.sendEvent(event)
  }
}

private var dragPanel: NSPanel?
private var grantWatch: Timer?

private func closeDragPanel() {
  grantWatch?.invalidate()
  grantWatch = nil
  dragPanel?.close()
  dragPanel = nil
}

// Opens the pane and shows the panel at the top right of the screen, where Settings leaves room.
func showDragIntoSettings(for grant: AppGrant) {
  openPrivacyPane(grant.pane)
  closeDragPanel()
  let panel = OwnInputIgnoringPanel(contentRect: CGRect(origin: .zero, size: panelSize),
                                    styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
  panel.titlebarAppearsTransparent = true
  panel.titleVisibility = .hidden
  panel.level = .floating
  panel.hidesOnDeactivate = false
  panel.isReleasedWhenClosed = false
  panel.contentView = NSHostingView(rootView: DragIntoSettingsView(title: ControlTexts.dragTitle(grant.name), close: closeDragPanel))
  if let frame = NSScreen.main?.visibleFrame {
    panel.setFrameOrigin(CGPoint(x: frame.maxX - panelSize.width - screenMargin, y: frame.maxY - panelSize.height - screenMargin))
  }
  panel.orderFrontRegardless()
  dragPanel = panel
  let until = Date().addingTimeInterval(panelLifetimeSeconds)
  grantWatch = Timer.scheduledTimer(withTimeInterval: grantCheckSeconds, repeats: true) { _ in
    if grantState(grant) == .granted || Date() > until { closeDragPanel() }
  }
}
