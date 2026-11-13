// System Settings: appearance through System Events, which owns the live setting, the output volume through
// Standard Additions, and panes through x-apple.systempreferences: links opened in the background.

import AppKit

private let systemEvents = "System Events"

private func automaticAppearance() -> Bool {
  UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyleSwitchesAutomatically"] as? Bool ?? false
}

private let getAppearance = Operation(name: "get_appearance", summary: "Read whether the Mac uses dark or light appearance", effect: .reads, arguments: []) { _ in
  let dark = try runScript("return Application('System Events').appearancePreferences.darkMode();", target: systemEvents) as? Bool
  guard let dark else { throw HelperError(code: "action_failed", message: "System Events gave an unexpected answer.") }
  return ["mode": dark ? "dark" : "light", "automatic": automaticAppearance()]
}

private let setAppearance = Operation(
  name: "set_appearance", summary: "Switch the Mac to dark or light appearance", effect: .changes,
  arguments: [Argument(name: "mode", kind: .string, required: true, description: "dark or light", allowed: ["dark", "light"])]
) { arguments in
  let wanted = try string(arguments, "mode")
  let dark = try runScript(#"""
    const preferences = Application('System Events').appearancePreferences;
    changeBegins({ mode: args.mode });
    preferences.darkMode = args.mode === 'dark';
    return preferences.darkMode();
    """#, arguments: arguments, target: systemEvents) as? Bool
  let mode = dark.map { $0 ? "dark" : "light" } ?? "unknown"
  return ["mode": mode, "verified": mode == wanted]
}

private let volumeScript = #"""
  const app = Application.currentApplication();
  app.includeStandardAdditions = true;
  if (args.level !== undefined || args.muted !== undefined) changeBegins({ level: args.level, muted: args.muted });
  if (args.level !== undefined) app.setVolume(null, { outputVolume: args.level });
  if (args.muted !== undefined) app.setVolume(null, { outputMuted: args.muted });
  const settings = app.getVolumeSettings();
  return { level: settings.outputVolume, muted: settings.outputMuted };
  """#

private let getVolume = Operation(name: "get_volume", summary: "Read the output volume (0 to 100) and whether it is muted", effect: .reads, arguments: []) { _ in
  try dictionary(runScript(volumeScript, target: "the audio volume"), from: "the audio volume")
}

private let setVolume = Operation(
  name: "set_volume", summary: "Set the output volume, mute or unmute", effect: .changes,
  arguments: [
    Argument(name: "level", kind: .integer, required: false, description: "0 to 100", minimum: 0, maximum: 100),
    Argument(name: "muted", kind: .boolean, required: false, description: "Mute or unmute"),
  ]
) { arguments in
  guard arguments["level"] != nil || arguments["muted"] != nil else {
    throw HelperError(code: "invalid_arguments", message: "Give level, muted or both.")
  }
  var result = try dictionary(runScript(volumeScript, arguments: arguments, target: "the audio volume"), from: "the audio volume")
  // Some outputs, such as HDMI, have no volume the Mac controls.
  let levelMatches = (arguments["level"] as? Int).map { level in (result["level"] as? Int).map { abs($0 - level) <= 1 } ?? false } ?? true
  let muteMatches = (arguments["muted"] as? Bool).map { $0 == result["muted"] as? Bool } ?? true
  result["verified"] = levelMatches && muteMatches
  return result
}

// The panes this Mac has: each is a system extension at this fixed place, so the list follows the macOS version.
private let paneExtensions = "/System/Library/ExtensionKit/Extensions"
private let paneExtensionPoint = "com.apple.Settings.extension.ui"
private let settingsBundleId = "com.apple.systempreferences"
private let paneOpenSeconds = 5.0

private func installedPanes() -> [(id: String, name: String)] {
  // Without the folder of panes, only the panes known by name are listed.
  let names = (try? FileManager.default.contentsOfDirectory(atPath: paneExtensions)) ?? []
  return names.filter { $0.hasSuffix(".appex") }.compactMap { name in
    guard let bundle = Bundle(path: "\(paneExtensions)/\(name)"), let id = bundle.bundleIdentifier,
      let attributes = bundle.object(forInfoDictionaryKey: "EXAppExtensionAttributes") as? [String: Any],
      attributes["EXExtensionPointIdentifier"] as? String == paneExtensionPoint
    else { return nil }
    let label = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName")) as? String
    return (id, label ?? String(name.dropLast(".appex".count)))
  }.sorted { $0.id < $1.id }
}

private func settingsWindowTitle() -> String? {
  guard let app = onMain({ NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleId).first { !$0.isTerminated } }) else { return nil }
  return windows(of: AXUIElementCreateApplication(app.processIdentifier)).first.flatMap { stringAttribute($0, kAXTitleAttribute) }
}

private let listPanes = Operation(name: "list_panes", summary: "List the panes this Mac's System Settings has, with ids for open_pane", effect: .reads, arguments: []) { _ in
  ["panes": installedPanes().map { ["id": $0.id, "name": $0.name] as JSON }]
}

private let openPane = Operation(
  name: "open_pane", summary: "Open a pane of System Settings behind the app you are in, ready for get_window_state", effect: .changes,
  arguments: [Argument(name: "pane", kind: .string, required: true, description: "Pane id from list_panes, such as com.apple.Sound-Settings.extension")]
) { arguments in
  try requireAccessibility()
  let id = try string(arguments, "pane")
  guard let pane = installedPanes().first(where: { $0.id == id }), let url = URL(string: "x-apple.systempreferences:\(pane.id)") else {
    throw HelperError(code: "not_found", message: "There is no pane \(id). Use list_panes.")
  }
  let before = settingsWindowTitle()
  let previous = onMain { NSWorkspace.shared.frontmostApplication }
  let configuration = NSWorkspace.OpenConfiguration()
  configuration.activates = false
  configuration.addsToRecentItems = false
  NSWorkspace.shared.open(url, configuration: configuration)
  // System Settings may take the focus while it starts; the app the user was in gets it back each time.
  var focusReturned = false
  var title: String?
  let deadline = Date().addingTimeInterval(paneOpenSeconds)
  var settledSince: Date?
  while Date() < deadline {
    if let previous, previous.bundleIdentifier != settingsBundleId,
      onMain({ NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) == settingsBundleId {
      focusReturned = onMain { previous.activate() } || focusReturned
    }
    title = settingsWindowTitle()
    if let title, !title.isEmpty, title != before || title == pane.name {
      settledSince = settledSince ?? Date()
      if Date().timeIntervalSince(settledSince!) > 0.5 { break }
    }
    sleep(seconds: 0.1)
  }
  var result: JSON = ["pane": pane.id, "window": title ?? "", "verified": settledSince != nil]
  if focusReturned { result["focus_returned"] = true }
  return result
}

let settingsKnowledge = AppKnowledge(
  bundleId: "com.apple.systempreferences", name: "System Settings", summary: "Read and set appearance and output volume, and open panes in the background",
  access: "Change system settings through System Events",
  hints: [
    "The sidebar lists panes; each pane is a scroll area of grouped rows whose switches and pop-up buttons can be pressed.",
    "In lists such as Full Disk Access, press a Row (or the text in it) to select it; Remove under the list then acts on it.",
  ],
  pitfalls: [
    "Opening a pane with an x-apple.systempreferences: link from a shell can bring System Settings to the front; open_pane keeps it behind.",
    "open_pane is verified by the window's title changing; when that pane was already open the title stays the same and verified is true only if it matches the pane's name.",
    "Setting a volume level also unmutes the output; pass muted: true with it to keep it silent.",
    "set_appearance changes the setting for every app and turns off automatic appearance.",
  ],
  operations: [listPanes, openPane, getAppearance, setAppearance, getVolume, setVolume])
