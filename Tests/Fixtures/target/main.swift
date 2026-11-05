// A small app for live tests. It logs what actually happened to it as JSON lines, so a test can check
// the effect instead of trusting what the driver reports.

import AppKit

let logPath = CommandLine.arguments.last ?? "/dev/null"

func log(_ event: String, _ detail: String = "") {
  let entry: [String: Any] = [
    "event": event, "detail": detail, "active": NSApp.isActive, "key_window": NSApp.keyWindow?.title ?? "",
  ]
  guard var data = try? JSONSerialization.data(withJSONObject: entry) else { return }
  data.append(0x0a)
  if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
  guard let handle = FileHandle(forWritingAtPath: logPath) else { return }
  _ = try? handle.seekToEnd()
  try? handle.write(contentsOf: data)
  try? handle.close()
}

// Has no accessibility actions, so only real mouse events reach it.
final class RawClickView: NSView {
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { log("raw_click", modifiers(event)) }
  override func rightMouseDown(with event: NSEvent) { log("raw_right_click", modifiers(event)) }
  override func otherMouseDown(with event: NSEvent) { log("raw_middle_click", modifiers(event)) }
  private func modifiers(_ event: NSEvent) -> String {
    let names: [(NSEvent.ModifierFlags, String)] = [(.command, "cmd"), (.shift, "shift"), (.option, "alt"), (.control, "ctrl")]
    return names.filter { event.modifierFlags.contains($0.0) }.map(\.1).joined(separator: "+")
  }
  override func keyDown(with event: NSEvent) { log("raw_key", event.charactersIgnoringModifiers ?? "") }
  override func scrollWheel(with event: NSEvent) { log("raw_scroll") }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.systemTeal.setFill()
    bounds.fill()
  }
}

final class Controller: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
  var windows: [NSWindow] = []
  var presses = 0
  let pressLabel = NSTextField(labelWithString: "presses: 0")
  let field = NSTextField(string: "")
  let secure = NSSecureTextField(string: "")
  let slider = NSSlider(value: 10, minValue: 0, maxValue: 100, target: nil, action: nil)
  let otherField = NSTextField(string: "")

  func applicationDidFinishLaunching(_ notification: Notification) {
    let main = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 420, height: 420), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    main.title = "Fixture Main"
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

    let press = NSButton(title: "Press Me", target: self, action: #selector(pressed))
    let sheet = NSButton(title: "Open Sheet", target: self, action: #selector(openSheet))
    let modal = NSButton(title: "Open Modal", target: self, action: #selector(openModal))
    field.placeholderString = "Plain"
    field.delegate = self
    field.identifier = NSUserInterfaceItemIdentifier("plain-field")
    secure.placeholderString = "Secret"
    slider.target = self
    slider.action = #selector(sliderMoved)

    let raw = RawClickView()
    raw.setAccessibilityElement(false)
    raw.translatesAutoresizingMaskIntoConstraints = false
    raw.widthAnchor.constraint(equalToConstant: 120).isActive = true
    raw.heightAnchor.constraint(equalToConstant: 60).isActive = true

    let scroll = NSScrollView(frame: .zero)
    scroll.hasVerticalScroller = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.heightAnchor.constraint(equalToConstant: 80).isActive = true
    scroll.widthAnchor.constraint(equalToConstant: 380).isActive = true
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 2000))
    text.string = (1...200).map { "line \($0)" }.joined(separator: "\n")
    text.isEditable = false
    scroll.documentView = text

    for view in [press, pressLabel, field, secure, slider, sheet, modal, raw, scroll] as [NSView] { stack.addArrangedSubview(view) }
    main.contentView = stack

    let second = NSWindow(contentRect: NSRect(x: 660, y: 300, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
    second.title = "Fixture Other"
    otherField.placeholderString = "Other"
    otherField.delegate = self
    let secondStack = NSStackView(views: [otherField])
    secondStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    second.contentView = secondStack
    second.orderFront(nil)
    // Last, so the main window is window 0 for the driver.
    main.orderFront(nil)
    windows = [main, second]
    main.contentView?.layoutSubtreeIfNeeded()
    let center = raw.convert(NSPoint(x: raw.bounds.midX, y: raw.bounds.midY), to: nil)
    log("ready", "\(Int(center.x)),\(Int(main.frame.height - center.y))")
  }

  @objc func pressed() {
    presses += 1
    pressLabel.stringValue = "presses: \(presses)"
    log("press", String(presses))
  }

  @objc func sliderMoved() { log("slider", String(slider.doubleValue)) }

  func controlTextDidChange(_ notification: Notification) {
    guard let control = notification.object as? NSTextField else { return }
    log(control === otherField ? "other_text" : "text", control.stringValue)
  }

  @objc func openSheet() {
    let alert = NSAlert()
    alert.messageText = "Fixture Sheet"
    alert.addButton(withTitle: "Close Sheet")
    alert.beginSheetModal(for: windows[0]) { _ in log("sheet_closed") }
    log("sheet_opened")
  }

  // A modal loop blocks the accessibility call that opened it.
  @objc func openModal() {
    log("modal_opened")
    let alert = NSAlert()
    alert.messageText = "Fixture Modal"
    alert.addButton(withTitle: "Close Modal")
    alert.runModal()
    log("modal_closed")
  }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
