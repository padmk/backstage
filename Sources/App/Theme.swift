// The look shared by Backstage's own windows: the colors of the app icon, its buttons and its sections.

import AppKit
import SwiftUI

// The app icon's colors: a deep navy stage, royal blue curtains and a cream pointer.
enum Palette {
  static let navy = Color(red: 0.07, green: 0.10, blue: 0.33)
  static let royal = Color(red: 0.16, green: 0.24, blue: 0.70)
  static let cream = Color(red: 0.96, green: 0.90, blue: 0.79)
  static let text = Color.white
  static let secondary = Color.white.opacity(0.68)
  static let amber = Color(red: 1.0, green: 0.76, blue: 0.35)
  static let sky = Color(red: 0.55, green: 0.68, blue: 1.0)
  static let coral = Color(red: 1.0, green: 0.55, blue: 0.52)
}

let cardRadius: CGFloat = 16

struct ChoiceStyle: ButtonStyle {
  // Deny, an ordinary choice, the main choice, and a choice that reaches every agent.
  enum Kind { case deny, plain, primary, everyone }
  let kind: Kind
  // Smaller, for buttons inside list rows.
  var compact = false

  func makeBody(configuration: ButtonStyleConfiguration) -> some View {
    configuration.label
      .font(.system(size: compact ? 12 : 13, weight: .semibold))
      .foregroundStyle(foreground)
      .padding(.horizontal, compact ? 10 : 12)
      .frame(minHeight: compact ? 26 : 32)
      .background(RoundedRectangle(cornerRadius: 8).fill(fill))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(kind == .deny ? Palette.coral.opacity(0.55) : .clear, lineWidth: 1))
      .opacity(configuration.isPressed ? 0.75 : 1)
      .contentShape(RoundedRectangle(cornerRadius: 8))
  }

  private var foreground: Color {
    switch kind {
    case .deny: Palette.coral
    case .primary: Palette.navy
    case .plain, .everyone: Palette.text
    }
  }

  private var fill: Color {
    switch kind {
    case .deny: .clear
    case .primary: Palette.cream
    case .plain: Color.white.opacity(0.14)
    case .everyone: Palette.sky.opacity(0.24)
    }
  }
}

struct CardSection<Content: View>: View {
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

func appIcon(path: String?, bundleIdentifier: String) -> NSImage? {
  if let path, FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
  return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    .map { NSWorkspace.shared.icon(forFile: $0.path) }
}

let brandGradient = LinearGradient(colors: [Palette.royal, Palette.navy], startPoint: .top, endPoint: .bottom)
