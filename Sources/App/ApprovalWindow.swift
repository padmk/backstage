// The native approval window: a small panel at the top of the screen, over the user's work. It never takes the
// keyboard, so typing meant for something else cannot answer it, and only a click does. The approving buttons
// unlock only once the pointer has moved and stayed over the window for a moment.

import AppKit
import SwiftUI

struct ApprovalLabels {
  let once: String
  let session: String
  let hour: String
  let day: String
  let always: String
  let decline: String
  let countdown: String
  let unlocked: String
  let moveHere: String
  let holdStill: String
  let ready: String
  let allowFor: String
  let bundleId: String
  let path: String
}

struct ApprovalRequest {
  let title: String
  let message: String
  // The location, with the bundle id, tells the real app from another one using its name.
  let path: String?
  let warning: String?
  let bundleIdentifier: String
  let offersAlways: Bool
  let timeoutSeconds: Int
  let labels: ApprovalLabels
}

enum Decision: String {
  case decline, once, session, hour, day, always
}

private let unlockDelaySeconds = 0.6
// How far the pointer may drift while it counts as resting.
private let restTolerance: CGFloat = 3
private let panelWidth: CGFloat = 520
private let topMargin: CGFloat = 10

// Never key, even when clicked or with keyboard navigation on, so keys keep going where the user was typing.
private final class ApprovalPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

// The panel is not key when the user reaches for a button, and that first click has to count.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct WindowBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .popover
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private func appIcon(path: String?, bundleIdentifier: String) -> NSImage? {
  if let path, FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
  return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    .map { NSWorkspace.shared.icon(forFile: $0.path) }
}

private enum GateState { case moveHere, holdStill, ready }

private struct ApprovalView: View {
  let request: ApprovalRequest
  let deadline: Date
  let decide: (Decision) -> Void
  @State private var gate = GateState.moveHere
  private var approvalUnlocked: Bool { gate == .ready }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 12) {
        Group {
          if let icon = appIcon(path: request.path, bundleIdentifier: request.bundleIdentifier) {
            Image(nsImage: icon).resizable()
          } else {
            Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
          }
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 3) {
          Text(request.title)
            .font(.system(size: 17, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
          Text(request.message)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
        identityRow(request.labels.bundleId, request.bundleIdentifier)
        if let path = request.path { identityRow(request.labels.path, path) }
      }
      .padding(.top, 12)

      if let warning = request.warning {
        Label {
          Text(warning).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 12)
      }

      HStack(spacing: 8) {
        Label(statusText, systemImage: approvalUnlocked ? "cursorarrow.click" : "lock.fill")
        Spacer(minLength: 8)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let remaining = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
          Text(request.labels.countdown.replacingOccurrences(
            of: "{time}", with: String(format: "%d:%02d", remaining / 60, remaining % 60)))
            .monospacedDigit()
            .fixedSize()
            .accessibilityHidden(true)
        }
      }
      .font(.system(size: 12))
      .foregroundStyle(.secondary)
      .frame(minHeight: 18)
      .padding(.top, 14)

      HStack(spacing: 8) {
        Button { decide(.decline) } label: { Text(request.labels.decline).frame(minWidth: 60) }
        Spacer(minLength: 8)
        Button(request.labels.once) { decide(.once) }.disabled(!approvalUnlocked)
        Button { decide(.session) } label: { Text(request.labels.session).frame(minWidth: 120) }
          .tint(approvalUnlocked ? .accentColor : .gray)
          .buttonStyle(.borderedProminent)
          .disabled(!approvalUnlocked)
      }
      .controlSize(.large)
      .padding(.top, 8)

      if request.offersAlways {
        HStack(spacing: 8) {
          Text(request.labels.allowFor).font(.system(size: 12)).foregroundStyle(.secondary)
          Spacer(minLength: 8)
          Button(request.labels.hour) { decide(.hour) }.disabled(!approvalUnlocked)
          Button(request.labels.day) { decide(.day) }.disabled(!approvalUnlocked)
          Button(request.labels.always) { decide(.always) }.disabled(!approvalUnlocked)
        }
        .controlSize(.large)
        .padding(.top, 8)
      }
    }
    .padding(20)
    .frame(width: panelWidth)
    .background(WindowBackground())
    .task {
      await watchForDeliberatePointer()
    }
  }

  private var statusText: String {
    switch gate {
    case .moveHere: request.labels.moveHere
    case .holdStill: request.labels.holdStill
    case .ready: request.labels.ready
    }
  }

  @ViewBuilder private func identityRow(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).font(.system(size: 11)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
      Text(value).font(.system(size: 12, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
  }

  // A pointer resting where the window appeared, or just passing through, says nothing about the user's
  // intent: it has to move onto the window and then rest there. People who do not use a pointer get the
  // buttons after the delay alone.
  private func watchForDeliberatePointer() async {
    let usesAssistiveTechnology = NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
    let start = NSEvent.mouseLocation
    var hasMoved = false
    var restingAt: NSPoint?
    var restingSince = Date()
    while !Task.isCancelled {
      let pointer = NSEvent.mouseLocation
      hasMoved = hasMoved || pointer != start
      let isOver = NSApp.windows.contains { $0 is ApprovalPanel && $0.isVisible && $0.frame.contains(pointer) }
      let next: GateState
      if usesAssistiveTechnology {
        next = Date().timeIntervalSince(restingSince) >= unlockDelaySeconds ? .ready : .holdStill
      } else if !(hasMoved && isOver) {
        restingAt = nil
        next = .moveHere
      } else if gate == .ready {
        next = .ready
      } else {
        if restingAt.map({ hypot(pointer.x - $0.x, pointer.y - $0.y) > restTolerance }) ?? true {
          restingAt = pointer
          restingSince = Date()
        }
        next = Date().timeIntervalSince(restingSince) >= unlockDelaySeconds ? .ready : .holdStill
      }
      if next != gate {
        gate = next
        if next == .ready { announceUnlocked() }
      }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  private func announceUnlocked() {
    NSAccessibility.post(
      element: NSApp as Any,
      notification: .announcementRequested,
      userInfo: [.announcement: request.labels.unlocked, .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }
}

// Blocks the calling worker thread until a decision is made. The window closes with the connection.
func askUser(_ request: ApprovalRequest, connection: Connection) -> Decision {
  #if TEST_APPROVALS
  if let forced = ProcessInfo.processInfo.environment["HELPER_TEST_DECISION"], forced != "window" {
    if forced == "hold" {
      while !connection.isCancelled { sleep(seconds: 0.02) }
      return .decline
    }
    testRecord(request)
    return Decision(rawValue: forced) ?? .decline
  }
  #endif
  let answered = DispatchSemaphore(value: 0)
  let lock = NSLock()
  var decision: Decision?
  var panel: NSPanel?

  let settle: (Decision) -> Void = { chosen in
    let isFirst = lock.withLock { () -> Bool in
      guard decision == nil else { return false }
      decision = chosen
      return true
    }
    guard isFirst else { return }
    DispatchQueue.main.async {
      panel?.orderOut(nil)
      panel = nil
    }
    answered.signal()
  }

  DispatchQueue.main.async {
    let deadline = Date().addingTimeInterval(TimeInterval(request.timeoutSeconds))
    let content = FirstClickHostingView(rootView: ApprovalView(request: request, deadline: deadline, decide: settle))
    content.layoutSubtreeIfNeeded()
    let window = ApprovalPanel(
      contentRect: NSRect(origin: .zero, size: content.fittingSize),
      styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    window.title = request.title
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.contentView = content

    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    if let visible = screen?.visibleFrame {
      let size = window.frame.size
      window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - topMargin))
    } else {
      window.center()
    }
    panel = window
    // The helper starts hidden, and a hidden app shows no window, not even one ordered front regardless.
    NSApp.unhideWithoutActivation()
    window.orderFrontRegardless()
    NSAccessibility.post(
      element: NSApp as Any,
      notification: .announcementRequested,
      userInfo: [.announcement: request.title, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    #if SELF_TEST
    runWindowSelfTest()
    #endif
  }

  let removeCancel = connection.onCancel { settle(.decline) }
  defer { removeCancel() }
  if answered.wait(timeout: .now() + .seconds(request.timeoutSeconds)) == .timedOut {
    settle(.decline)
  }
  return lock.withLock { decision ?? .decline }
}

#if TEST_APPROVALS
private func testRecord(_ request: ApprovalRequest) {
  guard let path = ProcessInfo.processInfo.environment["HELPER_TEST_RECORD"] else { return }
  let entry: JSON = [
    "title": request.title, "message": request.message, "warning": request.warning ?? NSNull(),
    "bundle_id": request.bundleIdentifier, "offers_always": request.offersAlways,
  ]
  guard var data = try? JSONSerialization.data(withJSONObject: entry) else { return }
  data.append(0x0a)
  if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
  guard let handle = FileHandle(forWritingAtPath: path) else { return }
  _ = try? handle.seekToEnd()
  try? handle.write(contentsOf: data)
  try? handle.close()
}
#endif

// Test builds only: sends key events to the window and reports what they did.
#if SELF_TEST
private func windowKey(_ code: UInt16, _ characters: String) -> NSEvent? {
  NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
    windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
}

private func runWindowSelfTest() {
  DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
    if let event = windowKey(36, "\r") { NSApp.sendEvent(event) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
      if let event = windowKey(53, "\u{1b}") { NSApp.sendEvent(event) }
    }
  }
}
#endif
