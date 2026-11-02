// The native approval window. It appears without taking the user's focus, under whatever they are doing, so
// input meant for something else must not grant access. Return never approves, and the approving buttons
// unlock only once the pointer has moved and stayed over the window for a moment.

import AppKit
import SwiftUI

struct ApprovalLabels {
  let session: String
  let hour: String
  let always: String
  let decline: String
  let countdown: String
  let unlocked: String
}

struct ApprovalRequest {
  let title: String
  let message: String
  let warning: String?
  let bundleIdentifier: String
  let brandName: String
  let offersAlways: Bool
  let timeoutSeconds: Int
  let labels: ApprovalLabels
}

enum Decision: String {
  case decline, session, hour, always
}

// Appears over the user's work without taking their focus: the app stays inactive, and keys keep going
// where they were going. Only clicking in the panel makes it key.
private let unlockDelaySeconds = 0.6

private final class ApprovalPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

// The panel is not key when the user reaches for a button, and that first click has to count.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct WindowBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct ApprovalIcon: View {
  let bundleIdentifier: String

  private var icon: NSImage? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
      .map { NSWorkspace.shared.icon(forFile: $0.path) }
  }

  var body: some View {
    Group {
      if let icon {
        Image(nsImage: icon).resizable()
      } else {
        Image(systemName: "cursorarrow.rays").font(.system(size: 64, weight: .light))
      }
    }
    .frame(width: 112, height: 112)
    .accessibilityHidden(true)
  }
}

private struct ApprovalView: View {
  let request: ApprovalRequest
  let deadline: Date
  let decide: (Decision) -> Void
  @State private var approvalUnlocked = false

  var body: some View {
    VStack(spacing: 0) {
      ApprovalIcon(bundleIdentifier: request.bundleIdentifier).padding(.bottom, 22)

      Text(request.brandName.uppercased())
        .font(.system(size: 12, weight: .semibold))
        .tracking(1.4)
        .foregroundStyle(.secondary)
        .padding(.bottom, 8)

      Text(request.title)
        .font(.system(size: 26, weight: .semibold))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 10)
        .accessibilityAddTraits(.isHeader)

      Text(request.message)
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      if let warning = request.warning {
        Label(warning, systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 13))
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 14)
      }

      VStack(spacing: 10) {
        Button { decide(.session) } label: {
          Text(request.labels.session).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!approvalUnlocked)

        if request.offersAlways {
          Button { decide(.hour) } label: {
            Text(request.labels.hour).frame(maxWidth: .infinity)
          }
          .disabled(!approvalUnlocked)

          Button { decide(.always) } label: {
            Text(request.labels.always).frame(maxWidth: .infinity)
          }
          .disabled(!approvalUnlocked)
        }

        Button { decide(.decline) } label: {
          Text(request.labels.decline).frame(maxWidth: .infinity)
        }
        .keyboardShortcut(.cancelAction)
      }
      .controlSize(.large)
      .padding(.top, 26)

      TimelineView(.periodic(from: .now, by: 1)) { context in
        let remaining = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
        Text(request.labels.countdown.replacingOccurrences(of: "{seconds}", with: String(remaining)))
          .font(.system(size: 12))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      .padding(.top, 14)
    }
    .padding(.horizontal, 44)
    .padding(.top, 40)
    .padding(.bottom, 24)
    .frame(width: 520)
    .background(WindowBackground())
    .task {
      await watchForDeliberatePointer()
    }
  }

  // A pointer resting where the window appeared, or just passing through, says nothing about the user's
  // intent. People who do not use a pointer get the window as key, and the delay alone.
  private func watchForDeliberatePointer() async {
    let usesKeyboard = NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled || NSApp.isFullKeyboardAccessEnabled
    let start = NSEvent.mouseLocation
    var hasMoved = false
    var heldSince: Date?
    while !Task.isCancelled {
      let pointer = NSEvent.mouseLocation
      hasMoved = hasMoved || pointer != start
      let isOver = NSApp.windows.contains { $0 is ApprovalPanel && $0.isVisible && $0.frame.contains(pointer) }
      if usesKeyboard || (hasMoved && isOver) {
        heldSince = heldSince ?? Date()
      } else {
        heldSince = nil
      }
      let shouldUnlock = heldSince.map { Date().timeIntervalSince($0) >= unlockDelaySeconds } ?? false
      if shouldUnlock != approvalUnlocked {
        approvalUnlocked = shouldUnlock
        if shouldUnlock { announceUnlocked() }
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
      window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
    } else {
      window.center()
    }
    panel = window
    window.orderFrontRegardless()
    if NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled || NSApp.isFullKeyboardAccessEnabled {
      window.makeKey()
    }
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
