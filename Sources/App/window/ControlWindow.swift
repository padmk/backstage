// The window people open themselves: the apps agents may use, the settings with the macOS permissions, and recent
// decisions, one tab each. Opening the app shows it.

import AppKit
import SwiftUI
import HelperLink

enum ControlTab: String, CaseIterable, Identifiable {
  case apps, setup, activity
  var id: String { rawValue }

  var title: String {
    switch self {
    case .apps: ControlTexts.appsTab
    case .setup: ControlTexts.setupTab
    case .activity: ControlTexts.activityTab
    }
  }

  var symbol: String {
    switch self {
    case .apps: "checkmark.shield"
    case .setup: "gearshape"
    case .activity: "clock.arrow.circlepath"
    }
  }
}

let controlWindowWidth: CGFloat = 640
private let controlWindowHeight: CGFloat = 600

final class ControlSelection: ObservableObject {
  @Published var tab: ControlTab {
    didSet { Preferences.lastTab = tab.rawValue }
  }

  init(_ tab: ControlTab) { self.tab = tab }
}

private struct TabBar: View {
  @ObservedObject var selection: ControlSelection
  let permissionsMissing: Bool

  var body: some View {
    HStack(spacing: 2) {
      ForEach(ControlTab.allCases) { tab in
        let chosen = selection.tab == tab
        Button { selection.tab = tab } label: {
          HStack(spacing: 6) {
            Image(systemName: tab.symbol)
            Text(tab.title)
          }
          // Laid over the tab, so the dot appearing does not widen it and move the bar sideways.
          .overlay(alignment: .topTrailing) {
            if tab == .setup, permissionsMissing {
              Circle().fill(Palette.amber).frame(width: 6, height: 6).offset(x: 7, y: 1)
            }
          }
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(chosen ? Palette.navy : Palette.secondary)
          .padding(.horizontal, 12)
          .frame(height: 28)
          .background(Capsule().fill(chosen ? Palette.cream : .clear))
          .contentShape(Capsule())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(3)
    .background(Capsule().fill(Color.black.opacity(0.22)))
  }
}

// The tab bar as the toolbar shows it, following the model for the missing-permission dot.
private struct ToolbarTabs: View {
  @ObservedObject var model: ControlModel
  @ObservedObject var selection: ControlSelection

  var body: some View {
    TabBar(selection: selection, permissionsMissing: model.permissionsMissing || model.grantsWaiting)
      .environment(\.colorScheme, .dark)
      .fixedSize()
  }
}

struct ControlView: View {
  @ObservedObject var model: ControlModel
  @ObservedObject var selection: ControlSelection

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        switch selection.tab {
        case .apps: AppsTab(model: model, showSetup: { selection.tab = .setup })
        case .setup: SetupTab(model: model)
        case .activity: ActivityTab(model: model)
        }
      }
      .padding(22)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: controlWindowWidth)
    .frame(maxHeight: .infinity)
    .background(brandGradient.ignoresSafeArea())
    .environment(\.colorScheme, .dark)
  }
}

// The tabs are the toolbar's one item, centered and level with the traffic lights. A view drawn under an empty
// toolbar instead gets no clicks: the toolbar takes them there to move the window.
private let tabsItem = NSToolbarItem.Identifier("tabs")

private final class TabsToolbar: NSObject, NSToolbarDelegate {
  private let tabs: NSView

  init(tabs: NSView) { self.tabs = tabs }

  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
               willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    guard identifier == tabsItem else { return nil }
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.view = tabs
    item.isBordered = false
    return item
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [tabsItem] }
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [tabsItem] }
}

// MARK: Pieces the tabs share

// One row geometry on every tab: a 12 pt inset, a 28 pt icon and a 10 pt gap, so text always starts in the same
// column and nothing moves sideways when the tab changes.
let rowInset: CGFloat = 12
let rowIconSide: CGFloat = 28
let rowIconGap: CGFloat = 10

enum RowIcon {
  case app(String)
  case symbol(String)
}

private struct RowIconView: View {
  let icon: RowIcon

  var body: some View {
    switch icon {
    case .app(let bundleId):
      appImage(bundleId: bundleId).resizable().frame(width: rowIconSide, height: rowIconSide)
    case .symbol(let name):
      // A tile, so a symbol has the weight of the app icons beside it.
      Image(systemName: name)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Palette.sky)
        .frame(width: rowIconSide, height: rowIconSide)
        .background(RoundedRectangle(cornerRadius: 7).fill(Palette.sky.opacity(0.18)))
    }
  }
}

// A row inside a list: an icon, a title with a detail line under it, and a control on the right.
struct ControlRow<Accessory: View>: View {
  let icon: RowIcon
  let title: String
  var detail: String? = nil
  var detailColor: Color = Palette.secondary
  var monospacedDetail = false
  @ViewBuilder let accessory: Accessory

  var body: some View {
    HStack(spacing: rowIconGap) {
      RowIconView(icon: icon).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
        if let detail {
          Text(detail).font(.system(size: 11, design: monospacedDetail ? .monospaced : .default))
            .foregroundStyle(detailColor).fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      accessory
    }
    .frame(minHeight: detail == nil ? 40 : 48)
  }
}

// Starts at the text column, as native grouped lists do.
struct RowDivider: View {
  var body: some View {
    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.leading, rowIconSide + rowIconGap)
  }
}

// A heading 26 pt high with an optional button on its right, an optional note under it, and the rows in a box.
struct ListSection<Trailing: View, Content: View>: View {
  let heading: String
  var note: String? = nil
  @ViewBuilder var trailing: Trailing
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(heading).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary)
        Spacer()
        trailing
      }
      .frame(height: 26)
      if let note {
        Text(note).font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 0) { content }
        .padding(.horizontal, rowInset)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
    }
  }
}

extension ListSection where Trailing == EmptyView {
  init(heading: String, note: String? = nil, @ViewBuilder content: () -> Content) {
    self.init(heading: heading, note: note, trailing: { EmptyView() }, content: content)
  }
}

// A centered icon and two lines, for a list with nothing in it yet.
struct EmptyState: View {
  let symbol: String
  let title: String
  let detail: String

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(Palette.sky)
      Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
      Text(detail).font(.system(size: 12)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 18)
  }
}

func appImage(bundleId: String) -> Image {
  appIcon(path: nil, bundleIdentifier: bundleId).map { Image(nsImage: $0) } ?? Image(systemName: "app.dashed")
}

func openPrivacyPane(_ pane: String) {
  if let url = URL(string: Product.privacyPaneURL(pane)) { NSWorkspace.shared.open(url) }
}

// MARK: The window

// After a restart the user asked for, the window opens again in front, in the process that replaces this one.
// A restart they did not ask for, such as after an update, leaves the window closed: bringing it back would
// open the app a second time, which macOS treats as the user reopening it and brings to the front.
private func scheduleReopen() {
  let script = Process()
  script.executableURL = URL(fileURLWithPath: "/bin/sh")
  script.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
  try? script.run()
}

func restartApp() {
  scheduleReopen()
  unlink(Configuration.socketPath)
  exit(0)
}

private final class ControlWindowCloser: NSObject, NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    // Back to having no Dock icon, as the background helper it also is.
    DispatchQueue.main.async {
      controlWindow = nil
      controlSelection = nil
      controlToolbar = nil
      NSApp.setActivationPolicy(.accessory)
    }
  }
}

private let closer = ControlWindowCloser()
private var controlWindow: NSWindow?
private var controlSelection: ControlSelection?
// The toolbar holds its delegate weakly.
private var controlToolbar: TabsToolbar?

var isControlWindowOpen: Bool { onMain { controlWindow != nil } }

// Standard keys for a window with a Dock icon. Quitting closes the window, because the app also serves agents.
private func controlMenu() -> NSMenu {
  let bar = NSMenu()
  let appItem = NSMenuItem()
  let appMenu = NSMenu()
  appMenu.addItem(withTitle: "Quit", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "q")
  appMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
  appItem.submenu = appMenu
  bar.addItem(appItem)
  let editItem = NSMenuItem()
  let editMenu = NSMenu(title: "Edit")
  editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
  editItem.submenu = editMenu
  bar.addItem(editItem)
  return bar
}

// Ignores every mouse and key event the helper itself posted, so an agent cannot change the list or the
// settings by clicking or typing into this window, whatever is in front.
private final class OwnInputIgnoringWindow: NSWindow {
  override func sendEvent(_ event: NSEvent) {
    if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return }
    super.sendEvent(event)
  }
}

// The window's frame: an opaque title bar band in the gradient's top color, holding the traffic lights and the
// tabs, with the content below it.
private func makeControlWindow(content: NSView, toolbar: TabsToolbar) -> NSWindow {
  let window = OwnInputIgnoringWindow(
    contentRect: NSRect(x: 0, y: 0, width: controlWindowWidth, height: controlWindowHeight),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered, defer: false)
  window.title = Configuration.appName
  window.titleVisibility = .hidden
  window.titlebarAppearsTransparent = true
  window.titlebarSeparatorStyle = .none
  window.backgroundColor = NSColor(Palette.royal)
  let bar = NSToolbar(identifier: "tabs")
  bar.delegate = toolbar
  bar.centeredItemIdentifiers = [tabsItem]
  bar.displayMode = .iconOnly
  bar.allowsUserCustomization = false
  window.toolbar = bar
  window.toolbarStyle = .unified
  window.appearance = NSAppearance(named: .darkAqua)
  window.isMovableByWindowBackground = true
  window.contentMinSize = NSSize(width: controlWindowWidth, height: 480)
  window.contentMaxSize = NSSize(width: controlWindowWidth, height: 900)
  window.contentView = content
  return window
}

// The tab is the one asked for, or the last one chosen; Setup while Accessibility is missing.
func showControlWindow(tab: ControlTab? = nil) {
  NSApp.setActivationPolicy(.regular)
  NSApp.mainMenu = controlMenu()
  let missing = !AXIsProcessTrusted()
  let chosen = tab ?? (missing ? .setup : Preferences.lastTab.flatMap(ControlTab.init(rawValue:)) ?? .apps)
  if let window = controlWindow, let selection = controlSelection {
    selection.tab = chosen
    window.makeKeyAndOrderFront(nil)
  } else {
    let selection = ControlSelection(chosen)
    let model = ControlModel()
    let toolbar = TabsToolbar(tabs: NSHostingView(rootView: ToolbarTabs(model: model, selection: selection)))
    let window = makeControlWindow(content: NSHostingView(rootView: ControlView(model: model, selection: selection)), toolbar: toolbar)
    window.isReleasedWhenClosed = false
    window.delegate = closer
    window.center()
    controlWindow = window
    controlSelection = selection
    controlToolbar = toolbar
    window.makeKeyAndOrderFront(nil)
  }
  // The one place this app comes forward, because the user opened it.
  NSApp.activate(ignoringOtherApps: true)
}
