// Draws each tab of the Backstage window into a PNG for the documentation: the whole tab at the window's width,
// at 2x, with the title bar band, the tabs, rounded corners and a shadow on a transparent background. It reads what
// the window would show this process, and never shows a window, takes the focus or changes anything.

import AppKit
import SwiftUI

// The band holding the traffic lights and the tabs, and the margin the shadow falls into.
private let titleBandHeight: CGFloat = 52
private let shadowMargin: CGFloat = 40
private let windowCornerRadius: CGFloat = 16
private let renderScale: CGFloat = 2

// The traffic lights as an inactive window shows them.
private struct InactiveTrafficLights: View {
  var body: some View {
    HStack(spacing: 9) {
      ForEach(0..<3, id: \.self) { _ in
        Circle().fill(Color.white.opacity(0.16)).frame(width: 14, height: 14)
      }
    }
  }
}

private struct RenderedWindow: View {
  let model: ControlModel
  let selection: ControlSelection

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        ToolbarTabs(model: model, selection: selection)
        InactiveTrafficLights().frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 19)
      }
      .frame(height: titleBandHeight)
      ControlContent(model: model, selection: selection).environment(\.colorScheme, .dark)
    }
    .frame(width: controlWindowWidth)
    .fixedSize(horizontal: false, vertical: true)
    .background(alignment: .top) {
      VStack(spacing: 0) {
        Palette.royal.frame(height: titleBandHeight)
        brandGradient
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    // Even all round: a vertical offset comes out mirrored in cacheDisplay.
    .shadow(color: .black.opacity(0.4), radius: 16)
    .padding(shadowMargin)
  }
}

// An NSHostingView in a borderless window that is never ordered in draws AppKit-backed controls such as the
// switches, which ImageRenderer leaves out.
@MainActor private func renderPNG(of view: some View) -> Data? {
  let hosting = NSHostingView(rootView: view)
  hosting.frame.size = hosting.fittingSize
  let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
  window.isOpaque = false
  window.backgroundColor = .clear
  window.appearance = NSAppearance(named: .darkAqua)
  window.contentView = hosting
  hosting.layoutSubtreeIfNeeded()
  // Lets SwiftUI finish its first update before the drawing.
  RunLoop.main.run(until: Date().addingTimeInterval(0.3))

  let size = hosting.bounds.size
  guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width * renderScale), pixelsHigh: Int(size.height * renderScale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)
  else { return nil }
  bitmap.size = size
  hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
  return bitmap.representation(using: .png, properties: [:])
}

// Writes window-apps.png, window-setup.png and window-activity.png into the folder; false when one failed.
@MainActor func renderControlWindow(into folder: String) -> Bool {
  let application = NSApplication.shared
  application.setActivationPolicy(.prohibited)
  let model = ControlModel()
  var succeeded = true
  for tab in ControlTab.allCases {
    let path = (folder as NSString).appendingPathComponent("window-\(tab.rawValue).png")
    guard let data = renderPNG(of: RenderedWindow(model: model, selection: ControlSelection(tab))),
      // Reported below with the path.
      (try? data.write(to: URL(fileURLWithPath: path))) != nil
    else {
      FileHandle.standardError.write(Data("Could not write \(path)\n".utf8))
      succeeded = false
      continue
    }
    print(path)
  }
  return succeeded
}
