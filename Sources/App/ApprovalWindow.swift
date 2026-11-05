// The native approval window: a small panel at the top of the screen, over the user's work. It never takes the
// keyboard, so typing meant for something else cannot answer it, and only a click does.

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
  let accessHeading: String
  let appHeading: String
  let thisAgent: String
  // The words between the two names in the heading.
  let wantsToControl: String
  let allAgents: String
  let bundleId: String
  let path: String
}

struct ApprovalRequest {
  // The heading as one sentence, for VoiceOver and the decision log.
  let title: String
  let requester: String
  let requesterIcon: NSImage?
  let appName: String
  // What approving lets the agent do, one line each.
  let access: [String]
  // The location, with the bundle id, tells the real app from another one using its name.
  let path: String?
  // Each its own line, shown before what the agent may do.
  let warnings: [String]
  let bundleIdentifier: String
  let offersAlways: Bool
  let timeoutSeconds: Int
  let labels: ApprovalLabels
}

enum Decision: String {
  case decline, once, session, hour, day, always
}

private let panelWidth: CGFloat = 600
private let topMargin: CGFloat = 10

// Never key, even when clicked or with keyboard navigation on, so keys keep going where the user was typing.
private final class ApprovalPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  // Pointer events this process posted, such as an agent's click_at, never answer the window; only the user's do.
  override func sendEvent(_ event: NSEvent) {
    if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return }
    super.sendEvent(event)
  }
}

// The panel is not key when the user reaches for a button, and that first click has to count.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// The app icon's colors: a deep navy stage, royal blue curtains and a cream pointer.
private enum Palette {
  static let navy = Color(red: 0.07, green: 0.10, blue: 0.33)
  static let royal = Color(red: 0.16, green: 0.24, blue: 0.70)
  static let cream = Color(red: 0.96, green: 0.90, blue: 0.79)
  static let text = Color.white
  static let secondary = Color.white.opacity(0.68)
  static let amber = Color(red: 1.0, green: 0.76, blue: 0.35)
  static let sky = Color(red: 0.55, green: 0.68, blue: 1.0)
  static let coral = Color(red: 1.0, green: 0.55, blue: 0.52)
}

private let cardRadius: CGFloat = 16

private struct ChoiceStyle: ButtonStyle {
  // Deny, a choice for this agent, the main choice, and a choice that reaches every agent.
  enum Kind { case deny, agent, primary, everyone }
  let kind: Kind

  func makeBody(configuration: ButtonStyleConfiguration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(foreground)
      .padding(.horizontal, 12)
      .frame(minHeight: 32)
      .background(RoundedRectangle(cornerRadius: 8).fill(fill))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(kind == .deny ? Palette.coral.opacity(0.55) : .clear, lineWidth: 1))
      .opacity(configuration.isPressed ? 0.75 : 1)
      .contentShape(RoundedRectangle(cornerRadius: 8))
  }

  private var foreground: Color {
    switch kind {
    case .deny: Palette.coral
    case .primary: Palette.navy
    case .agent, .everyone: Palette.text
    }
  }

  private var fill: Color {
    switch kind {
    case .deny: .clear
    case .primary: Palette.cream
    case .agent: Color.white.opacity(0.14)
    case .everyone: Palette.sky.opacity(0.24)
    }
  }
}

// A small captioned group of buttons, so the choices read as sections in one row.
private struct ChoiceGroup<Content: View>: View {
  let caption: String?
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(caption ?? " ").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary)
      HStack(spacing: 6) { content }
    }
  }
}

private struct Section<Content: View>: View {
  let heading: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(heading).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary)
      VStack(alignment: .leading, spacing: 6) { content }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
    }
  }
}

// An icon drawn as text, sized with the heading's font so it sits on its line.
private func inlineIcon(_ image: NSImage?, fallback: String, fontSize: CGFloat) -> Text {
  let side = (fontSize * 1.4).rounded()
  guard let image, let sized = image.copy() as? NSImage else {
    return Text(Image(systemName: fallback)).foregroundColor(Palette.secondary)
  }
  sized.size = NSSize(width: side, height: side)
  return Text(Image(nsImage: sized)).baselineOffset(-(side - fontSize) / 2 - fontSize * 0.12)
}

// The heading fills its row: the largest of these sizes that fits on one line, and below the smallest it wraps.
private let headingSizes: [CGFloat] = Array(stride(from: 30, through: 17, by: -1))

private func appIcon(path: String?, bundleIdentifier: String) -> NSImage? {
  if let path, FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
  return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    .map { NSWorkspace.shared.icon(forFile: $0.path) }
}


private struct ApprovalView: View {
  let request: ApprovalRequest
  let deadline: Date
  let decide: (Decision) -> Void

  private func heading(_ size: CGFloat) -> Text {
    let requesterIcon = inlineIcon(request.requesterIcon, fallback: "terminal", fontSize: size)
    let requester = Text(request.requester).foregroundColor(Palette.sky).fontWeight(.semibold)
    let wants = Text(request.labels.wantsToControl).foregroundColor(Palette.secondary)
    let targetIcon = inlineIcon(appIcon(path: request.path, bundleIdentifier: request.bundleIdentifier), fallback: "app.dashed", fontSize: size)
    let target = Text(request.appName).foregroundColor(Palette.cream).fontWeight(.semibold)
    return Text("\(requesterIcon) \(requester) \(wants) \(targetIcon) \(target)")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Says whose window this is, since it has no title bar.
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 56, height: 56)
        .accessibilityLabel(Configuration.appName)
        .frame(maxWidth: .infinity)

      ViewThatFits(in: .horizontal) {
        ForEach(headingSizes, id: \.self) { size in
          heading(size).font(.system(size: size)).lineLimit(1).fixedSize()
        }
        heading(17).font(.system(size: 17)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 8)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(request.title)
      .accessibilityAddTraits(.isHeader)

      Section(heading: request.labels.accessHeading) {
        ForEach(request.warnings, id: \.self) { warning in
          Label {
            Text(warning).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.amber)
          }
        }
        ForEach(request.access, id: \.self) { line in
          Text(line).font(.system(size: 13)).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.top, 14)

      Section(heading: request.labels.appHeading) {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
          identityRow(request.labels.bundleId, request.bundleIdentifier)
          if let path = request.path { identityRow(request.labels.path, path) }
        }
      }
      .padding(.top, 10)

      HStack(alignment: .bottom, spacing: 0) {
        ChoiceGroup(caption: nil) {
          Button(request.labels.decline) { decide(.decline) }.buttonStyle(ChoiceStyle(kind: .deny))
        }
        Spacer(minLength: 20)
        ChoiceGroup(caption: request.labels.thisAgent) {
          Button(request.labels.once) { decide(.once) }.buttonStyle(ChoiceStyle(kind: .primary))
          Button(request.labels.session) { decide(.session) }.buttonStyle(ChoiceStyle(kind: .agent))
        }
        if request.offersAlways {
          Spacer(minLength: 20).frame(maxWidth: 24)
          ChoiceGroup(caption: request.labels.allAgents) {
            Button(request.labels.hour) { decide(.hour) }.buttonStyle(ChoiceStyle(kind: .everyone))
            Button(request.labels.day) { decide(.day) }.buttonStyle(ChoiceStyle(kind: .everyone))
            Button(request.labels.always) { decide(.always) }.buttonStyle(ChoiceStyle(kind: .everyone))
          }
        }
      }
      .padding(.top, 16)

      TimelineView(.periodic(from: .now, by: 1)) { context in
        let remaining = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
        Text(request.labels.countdown.replacingOccurrences(
          of: "{time}", with: String(format: "%d:%02d", remaining / 60, remaining % 60)))
          .font(.system(size: 11))
          .monospacedDigit()
          .foregroundStyle(Palette.secondary)
          .frame(maxWidth: .infinity)
          .accessibilityHidden(true)
      }
      .padding(.top, 10)
    }
    .padding(22)
    .frame(width: panelWidth)
    .background(LinearGradient(colors: [Palette.royal, Palette.navy], startPoint: .top, endPoint: .bottom))
    .clipShape(RoundedRectangle(cornerRadius: cardRadius))
    .overlay(RoundedRectangle(cornerRadius: cardRadius).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    .environment(\.colorScheme, .dark)
  }

  @ViewBuilder private func identityRow(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).font(.system(size: 11)).foregroundStyle(Palette.secondary).gridColumnAlignment(.trailing)
      // The full width of the card, so a path wraps only when it does not fit.
      Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
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
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    window.title = request.title
    // The view draws its own rounded, opaque card; the window around it is clear so its corners stay round.
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
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
    "title": request.title, "requester": request.requester, "access": request.access, "warning": request.warnings.isEmpty ? NSNull() : request.warnings.joined(separator: " "),
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
