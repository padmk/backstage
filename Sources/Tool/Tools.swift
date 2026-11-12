// The MCP tools and their argument checks. Bad arguments stop here, before any request reaches an app.

import Foundation
import HelperLink

typealias JSON = [String: Any]

private let app: JSON = ["type": "string", "description": "App name, bundle id or pid"]
private let window: JSON = ["type": "integer", "minimum": 0, "description": "Window index shown in get_window_state; default the first"]
private let element: JSON = ["type": "integer", "minimum": 1, "description": "Element number from get_window_state"]

private func described(_ rule: JSON, _ description: String) -> JSON {
  var copy = rule
  copy["description"] = description
  return copy
}

// Tools that only read say so, so a client can allow or batch them. Of the tools that act on apps, those that
// only arrange, show or start them are not destructive; input can replace or delete what an app holds, so it is.
private let reads: JSON = ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false]
private let acts: JSON = ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false]
private let changes: JSON = ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": false]

struct ToolDefinition {
  let name: String
  let description: String
  let properties: [(String, JSON)]
  let required: [String]
  let annotations: JSON

  var inputSchema: JSON {
    ["type": "object", "properties": Dictionary(uniqueKeysWithValues: properties), "required": required, "additionalProperties": false]
  }

  var listed: JSON { ["name": name, "description": description, "inputSchema": inputSchema, "annotations": annotations] }

  func rule(for key: String) -> JSON? { properties.first { $0.0 == key }?.1 }
}

// The apps with ready operations, kept in step with the app's catalog (Sources/App/apps/Catalog.swift; a helper test
// compares the two), so an agent can go straight to list_operations for one of them.
private let appsWithOperations = "Notes, Reminders, Calendar, Contacts, Mail, Messages, WhatsApp, Finder, Pages, Numbers, Music, Photos, Shortcuts and System Settings"

// The tools run_actions can run as steps, with their own arguments except app.
let stepTools = actionToolNames

let tools: [ToolDefinition] = [
  ToolDefinition(
    name: "list_apps",
    description: "List running apps with `access` for each: `allowed`, `not_approved` (not on the user's list) or `never_available`. With app: that app, running or installed, without starting it. Check this before using an app by any route. Being listed here does not allow an app. `screen_locked: true` means windows cannot be read until the user unlocks the Mac; ready operations and the menu bar still work, and with `windows_while_locked` (the user's setting) so do screenshot, click_at with x and y, and press_key and type_text without an element, unverified.",
    properties: [("app", ["type": "string", "description": "App name or bundle id"])],
    required: [], annotations: reads),
  ToolDefinition(
    name: "launch_app",
    description: "Start an app in the background, or with files hand it files to open, such as a recording for a speech-to-text app. Needs the app on the list. If it takes the focus while starting or opening the files, the app you were in gets it back and the app stays behind it. An app that is already running and gets no files is left as it is.",
    properties: [
      ("app", ["type": "string", "description": "App name or bundle id, not a path"]),
      ("files", ["type": "array", "minItems": 1, "maxItems": 20, "items": ["type": "string"] as JSON, "description": "Absolute paths of files to open in the app: your own files, or copies Backstage made, such as record_audio's recordings"]),
    ],
    required: ["app"], annotations: acts),
  ToolDefinition(
    name: "list_operations",
    description: "List the ready operations, hints and pitfalls Backstage knows for well-known apps: \(appsWithOperations) have operations. With app: its operations and their arguments; without: every app with hints. Prefer an operation to working through the window: it is faster, runs in the background and checks its own result. Listing works for any app; running an operation needs the app on the list.",
    properties: [("app", ["type": "string", "description": "App name or bundle id"])],
    required: [], annotations: reads),
  ToolDefinition(
    name: "run_operation",
    description: "Run one operation from list_operations. The reply carries the result and, for a change, `verified`. `outcome_unknown` means the change may have been made: read the state before trying again.",
    properties: [
      ("app", ["type": "string", "description": "App name or bundle id"]),
      ("operation", ["type": "string", "description": "Operation name from list_operations, such as create"]),
      ("arguments", ["type": "object", "description": "The operation's arguments, as list_operations describes them"]),
    ],
    required: ["app", "operation"], annotations: changes),
  ToolDefinition(
    name: "get_window_state",
    description: "Read a window as lines of numbered elements with their state and actions. The first line lists the app's windows. Numbers stay valid across reads in this session; a new session numbers elements anew, so read again before using a number from another one. Reading the same place again returns only what changed since your last read or action there; pass full: true for all of it.",
    properties: [
      ("app", app),
      ("window", window),
      ("full", ["type": "boolean", "description": "Return every element even when an earlier read of this place exists"]),
      ("screenshot", ["type": "boolean", "description": "Also capture the window as a PNG, as the screenshot tool does (needs Screen Recording)"]),
      ("menu_bar", ["type": "boolean", "description": "Read the menu bar instead of a window"]),
      ("menu_extras", ["type": "boolean", "description": "Read the app's items on the right of the menu bar, such as status icons, instead of a window"]),
      ("root", described(element, "Read only this element's subtree")),
      ("max_elements", ["type": "integer", "minimum": 1, "maximum": 5000, "description": "Default 800. A read cut at this limit is partial, and an action after it cannot report what changed; to read less, use root"]),
    ],
    required: ["app"], annotations: reads),
  ToolDefinition(
    name: "read_text",
    description: "Read the full text of an element, or part of it, where get_window_state cuts a long value or label (it then shows length= or label_length=); an element without a text value gives its label, and source says which. start and length count UTF-16 units, like select_text; the reply says the total and whether more follows.",
    properties: [("app", app), ("element", element), ("start", ["type": "integer", "minimum": 0]), ("length", ["type": "integer", "minimum": 1, "maximum": 50000])],
    required: ["app", "element"], annotations: reads),
  ToolDefinition(
    name: "screenshot",
    description: "Capture a window as a PNG, one image pixel per window point, so its coordinates work with click_at. Needs Screen Recording, which is optional: without it the reply is permission_missing and the Backstage window shows the user an Allow button; meanwhile, work from get_window_state. With text: true the reply also lists the text recognized in the image on this Mac, for views without elements: each line's text, confidence (0 to 1) and frame [x, y, width, height] in window points from the top left, top to bottom, with text_truncated: true when the list was cut, or text_error instead when recognition fails. Recognized text can be wrong and does not prove that an action worked.",
    properties: [("app", app), ("window", window),
                 ("text", ["type": "boolean", "description": "Also recognize the text in the image (default false)"])],
    required: ["app"], annotations: reads),
  ToolDefinition(
    name: "press",
    description: "Press an element without taking focus, or run one of the actions it lists. A list row without actions, or the text in one, is selected. The reply's `state` reports what changed in the area last read once the app settles (`settled: false` if it was still busy), or `unknown` when it cannot tell; `verified: false` means delivery could not be confirmed.",
    properties: [("app", app), ("element", element), ("action", ["type": "string", "description": "An action the element lists, such as ShowMenu. Default: press"])],
    required: ["app", "element"], annotations: changes),
  ToolDefinition(
    name: "set_value",
    description: "Replace the value of an editable element.",
    properties: [("app", app), ("element", element), ("value", ["type": "string"])],
    required: ["app", "element", "value"], annotations: changes),
  ToolDefinition(
    name: "type_text",
    description: "Insert text at an element, or without one send it as keys to the app's focused element. Delivery `value_appended_at_end` means an unfocused one-line field took it at its end, ignoring the cursor. Line breaks and tabs need an element that takes text directly; otherwise send them with press_key. Nothing is typed if the element cannot take it.",
    properties: [("app", app), ("text", ["type": "string", "maxLength": 100000]), ("element", element)],
    required: ["app", "text"], annotations: changes),
  ToolDefinition(
    name: "select_text",
    description: "Select text in a field or document by what it says, or put the cursor just before or after it, so type_text then replaces the selection or inserts there instead of rewriting the whole value. Give text exactly as the element's value has it; when it occurs more than once, add prefix or suffix text around it until it occurs once.",
    properties: [
      ("app", app),
      ("element", element),
      ("text", ["type": "string", "maxLength": 10000]),
      ("prefix", ["type": "string", "maxLength": 1000, "description": "Text right before it, to pick one occurrence"]),
      ("suffix", ["type": "string", "maxLength": 1000, "description": "Text right after it, to pick one occurrence"]),
      ("place", ["type": "string", "enum": ["select", "before", "after"], "description": "Select the text (default), or put the cursor before or after it"]),
    ],
    required: ["app", "element", "text"], annotations: acts),
  ToolDefinition(
    name: "press_key",
    description: "Send a key or combination, such as return or cmd+s, to the app in the background. A native view receives it once it has focus, so click the view with click_at first. Other apps and combinations may behave differently, so check the effect, and prefer pressing the menu item.",
    properties: [("app", app), ("key", ["type": "string", "maxLength": 64])],
    required: ["app", "key"], annotations: changes),
  ToolDefinition(
    name: "scroll",
    description: "Scroll the area containing an element.",
    properties: [
      ("app", app), ("element", element),
      ("direction", ["type": "string", "enum": ["up", "down", "left", "right"]]),
      ("pages", ["type": "integer", "minimum": 1, "maximum": 20]),
    ],
    required: ["app", "element", "direction"], annotations: acts),
  ToolDefinition(
    name: "drag",
    description: "Drag from one place to another in the background, without moving the cursor: a slider's knob, an item onto a target, a selection. Each end is an element number or a point in window coordinates. Check the effect in `state` or with a screenshot.",
    properties: [
      ("app", app), ("window", window),
      ("from_element", described(element, "Element to drag from, at its center")),
      ("from_x", ["type": "number", "minimum": 0]), ("from_y", ["type": "number", "minimum": 0]),
      ("to_element", described(element, "Element to drag to, at its center")),
      ("to_x", ["type": "number", "minimum": 0]), ("to_y", ["type": "number", "minimum": 0]),
    ],
    required: ["app"], annotations: changes),
  ToolDefinition(
    name: "click_at",
    description: "Send a click at a point in window coordinates, or at an element's center, in the background and without moving the cursor. Use it when press cannot do the job, such as a right-click, a cmd-click or a view without elements, and check the effect, for example with a screenshot.",
    properties: [
      ("app", app),
      ("element", described(element, "Click this element's center instead of a point")),
      ("x", ["type": "number", "minimum": 0]), ("y", ["type": "number", "minimum": 0]),
      ("window", window),
      ("count", ["type": "integer", "minimum": 1, "maximum": 3]),
      ("button", ["type": "string", "enum": ["left", "right", "middle"], "description": "Default: left"]),
      ("modifiers", ["type": "array", "maxItems": 4, "items": ["type": "string", "enum": ["cmd", "shift", "alt", "ctrl"]] as JSON, "description": "Keys held during the click"]),
      ("foreground", ["type": "boolean", "description": "Last resort when a background click did not land: the window comes forward for the click, then the previous app gets the focus back and the cursor returns. Tell the user you used it."]),
    ],
    required: ["app"], annotations: changes),
  ToolDefinition(
    name: "list_windows",
    description: "List windows across apps and displays: each window's id, app, frame (global points, origin at the top left of the main display), display, whether it is on screen, and for apps on the user's list its title, window number, minimized, fullscreen, modal, movable and resizable. Displays come with their frame and visible area (without the menu bar and the Dock). Windows of apps not on the list show no title. space is current, other or unknown: Accessibility reaches only windows on the current Space.",
    properties: [("app", ["type": "string", "description": "Only this app's windows"])],
    required: [], annotations: reads),
  ToolDefinition(
    name: "set_window",
    description: "Change one window in one way: frame, layout, minimized or fullscreen (exactly one). The reply reads the frame back: verified when it matches within 2 points, adjusted when the app kept it within its own limits. Bringing a window back from the Dock or into full screen puts it in front, so it needs foreground: true; tell the user. Windows on another Space cannot be changed.",
    properties: [
      ("app", app),
      ("id", ["type": "integer", "minimum": 1, "description": "Window id from list_windows"]),
      ("window", window),
      ("frame", ["type": "object", "description": "{x, y, width, height} in global points"]),
      ("layout", ["type": "string", "enum": ["maximize", "center", "left_half", "right_half", "top_half", "bottom_half", "top_left", "top_right", "bottom_left", "bottom_right", "left_third", "center_third", "right_third", "left_two_thirds", "right_two_thirds"], "description": "Place the window in a part of a display's visible area"]),
      ("display", ["type": ["integer", "string"], "description": "With layout: a display id from list_windows, next or previous; default the window's own"]),
      ("minimized", ["type": "boolean"]),
      ("fullscreen", ["type": "boolean"]),
      ("foreground", ["type": "boolean", "description": "Allow a change that brings the window in front (minimized: false, fullscreen)"]),
    ],
    required: ["app"], annotations: acts),
  ToolDefinition(
    name: "set_app_state",
    description: "Hide an app's windows, or show them again without bringing the app forward.",
    properties: [("app", app), ("state", ["type": "string", "enum": ["hidden", "shown"]])],
    required: ["app", "state"], annotations: acts),
  ToolDefinition(
    name: "close",
    description: "Close a window through its close button, or quit the app (quit: true) as if the user chose Quit. Nothing is forced: when the app asks about unsaved work the reply is outcome_unknown; read its window and answer, or tell the user.",
    properties: [
      ("app", app),
      ("id", ["type": "integer", "minimum": 1, "description": "Window id from list_windows"]),
      ("window", window),
      ("quit", ["type": "boolean", "description": "Quit the app instead of closing one window"]),
    ],
    required: ["app"], annotations: changes),
  ToolDefinition(
    name: "list_menu_commands",
    description: "List what an app can do from its menu bar: each command's path (such as File > Export…), keyboard shortcut, enabled state and element number, without opening a menu. Use it to find a command instead of exploring the window; query narrows it. Commands that act on the current document are disabled while the app is in the background. The Apple, Services and Share menus are never available.",
    properties: [
      ("app", app),
      ("query", ["type": "string", "description": "Only commands whose path or shortcut contains this"]),
      ("enabled_only", ["type": "boolean"]),
      ("max", ["type": "integer", "minimum": 1, "maximum": 2000, "description": "Default 300"]),
    ],
    required: ["app"], annotations: reads),
  ToolDefinition(
    name: "run_menu_command",
    description: "Run one menu command by its path (File > Export…; the last title alone when it is unique) or its shortcut (cmd+shift+s), in the background, without opening the menu or typing the shortcut. It is refused when disabled or ambiguous, with the matches. The reply's state reports what changed; a toggle is verified by its checkmark.",
    properties: [
      ("app", app),
      ("command", ["type": "string", "maxLength": 500, "description": "Menu path, separated by >"]),
      ("shortcut", ["type": "string", "maxLength": 64, "description": "Such as cmd+shift+s"]),
    ],
    required: ["app"], annotations: changes),
  ToolDefinition(
    name: "wait_for",
    description: "Wait until text shows in a window (a dialog, a result, a label), or with gone: true until it stops showing, for up to timeout seconds (default 10, at most 30). It reads the same place get_window_state reads (window, menu_bar, root). The reply says whether it was found and the matching line, preferring one whose title or value is exactly the text.",
    properties: [
      ("app", app),
      ("text", ["type": "string", "maxLength": 1000]),
      ("role", ["type": "string", "description": "Only elements of this role or subrole, such as Button or Sheet"]),
      ("gone", ["type": "boolean"]),
      ("timeout", ["type": "number", "minimum": 0.5, "maximum": 30]),
      ("window", window),
      ("menu_bar", ["type": "boolean"]),
      ("root", described(element, "Look only in this element's subtree")),
    ],
    required: ["app", "text"], annotations: reads),
  ToolDefinition(
    name: "record_audio",
    description: "Record what an app plays into an .m4a file, muted for the user so they do not hear it, for example to transcribe a voice message that cannot be downloaded. Give press with the element that starts playback (such as a Play button): it is pressed once the recording runs, so the start is not missed. The recording ends after until_silent seconds without sound once sound was heard, or at seconds. The reply gives the file's path, its length, heard_sound and how it ended. Needs System Audio Recording: without it the reply is permission_missing and the Backstage window shows the user an Allow button. A playback speed set in the app applies to the recording.",
    properties: [
      ("app", app),
      ("press", described(element, "Element to press once the recording runs, such as a Play button")),
      ("seconds", ["type": "number", "minimum": 1, "maximum": 180, "description": "Longest recording; default 60"]),
      ("until_silent", ["type": "number", "minimum": 0.5, "maximum": 30, "description": "End after this long without sound once sound was heard; default 3"]),
    ],
    required: ["app"], annotations: acts),
  ToolDefinition(
    name: "run_actions",
    description: "Run up to \(maxSteps) actions in one app in order, then report the combined change once, saving a round trip per step. Each step is {\"tool\": one of \(stepTools.joined(separator: ", ")), plus that tool's arguments without app}, such as {\"tool\":\"set_value\",\"element\":4,\"value\":\"Paris\"}. Use element numbers you have already read: elements a step makes appear have no number yet. Steps stop at the first that fails or may have worked (`failed` names it); a step that was delivered but cannot be confirmed, such as a click by position (`verified: false`), does not stop the others. Nothing is retried, so read the state before going on.",
    properties: [
      ("app", app),
      ("steps", ["type": "array", "minItems": 1, "maxItems": maxSteps, "items": ["type": "object", "properties": ["tool": ["type": "string", "enum": stepTools]] as JSON, "required": ["tool"]] as JSON]),
    ],
    required: ["app", "steps"], annotations: changes),
]

let toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

// MARK: Argument checks

// JSON from Foundation keeps true and false as numbers, so they are told apart by their Core Foundation type.
private func isBoolean(_ value: Any) -> Bool {
  guard let number = value as? NSNumber else { return false }
  return CFGetTypeID(number) == CFBooleanGetTypeID()
}

private func numberValue(_ value: Any) -> Double? {
  guard !isBoolean(value), let number = value as? NSNumber else { return nil }
  return number.doubleValue
}

// The same rule as JavaScript's Number.isSafeInteger, which the tool schemas are written for.
private let maxSafeInteger = 9_007_199_254_740_991.0

// Lengths count UTF-16 units, as the schemas' maxLength does in JavaScript.
private func length(_ value: Any) -> Int? {
  if let text = value as? String { return (text as NSString).length }
  if let list = value as? [Any] { return list.count }
  return nil
}

private func describeLimit(_ value: Any) -> String {
  if let number = numberValue(value), number == number.rounded() { return String(Int(number)) }
  return "\(value)"
}

private func problem(_ key: String, _ value: Any, _ rule: JSON) -> String? {
  let type = rule["type"] as? String
  if type == "string", !(value is String) { return "\(key) must be a string" }
  if type == "boolean", !isBoolean(value) { return "\(key) must be true or false" }
  if type == "object", !(value is [String: Any]) { return "\(key) must be an object" }
  if type == "array", !(value is [Any]) { return "\(key) must be a list" }
  if let minimum = rule["minItems"] as? Int, let count = length(value), count < minimum { return "\(key) needs at least \(minimum) items" }
  if let maximum = rule["maxItems"] as? Int, let count = length(value), count > maximum { return "\(key) takes at most \(maximum) items" }
  if type == "array", let items = rule["items"] as? JSON, let allowed = items["enum"] as? [String], let list = value as? [Any],
     !list.allSatisfy({ ($0 as? String).map(allowed.contains) ?? false }) {
    return "\(key) items must be among \(allowed.joined(separator: ", "))"
  }
  if type == "array", let items = rule["items"] as? JSON, items["type"] as? String == "string", let list = value as? [Any],
     !list.allSatisfy({ $0 is String }) {
    return "\(key) items must be strings"
  }
  if type == "integer" {
    guard let number = numberValue(value), number.isFinite, number == number.rounded(), abs(number) <= maxSafeInteger else { return "\(key) must be a whole number" }
  }
  if type == "number" {
    guard let number = numberValue(value), number.isFinite else { return "\(key) must be a number" }
  }
  if let minimum = rule["minimum"], let number = numberValue(value), let limit = numberValue(minimum), number < limit { return "\(key) must be at least \(describeLimit(minimum))" }
  if let maximum = rule["maximum"], let number = numberValue(value), let limit = numberValue(maximum), number > limit { return "\(key) must be at most \(describeLimit(maximum))" }
  if let maximum = rule["maxLength"] as? Int, let count = length(value), count > maximum { return "\(key) is too long" }
  if let allowed = rule["enum"] as? [String], !((value as? String).map(allowed.contains) ?? false) { return "\(key) must be one of \(allowed.joined(separator: ", "))" }
  return nil
}

// A description of what is wrong with the arguments of a call, or nil. `keys` gives the order the client sent
// them in, so the first problem reported is the first in the request.
func validateArguments(_ name: String, _ arguments: Any, keys: [String]? = nil) -> String? {
  guard let arguments = arguments as? JSON, let tool = toolsByName[name] else { return "arguments must be an object" }
  for key in tool.required where arguments[key] == nil { return "\(key) is required" }
  for key in keys ?? arguments.keys.sorted() {
    guard let value = arguments[key] else { continue }
    guard let rule = tool.rule(for: key) else { return "unknown argument \(key)" }
    if let found = problem(key, value, rule) { return found }
  }
  if name == "run_actions", let steps = arguments["steps"] as? [Any] { return problemWithSteps(steps) }
  return nil
}

// Places the schema cannot require, since either an element or a point will do; checked before any step runs.
private func missingPlace(_ name: String, _ arguments: JSON) -> String? {
  func placed(_ prefix: String) -> Bool {
    arguments["\(prefix)element"] != nil || (arguments["\(prefix)x"] != nil && arguments["\(prefix)y"] != nil)
  }
  if name == "click_at", !placed("") { return "give element, or x and y" }
  if name == "drag", !(placed("from_") && placed("to_")) { return "give from_element or from_x and from_y, and to_element or to_x and to_y" }
  return nil
}

// Each step is checked as a call of its own tool, so a bad step is refused before any step runs.
private func problemWithSteps(_ steps: [Any]) -> String? {
  for (index, step) in steps.enumerated() {
    guard var rest = step as? JSON else { return "step \(index + 1) must be an object" }
    let stepTool = rest.removeValue(forKey: "tool")
    guard let name = stepTool as? String, stepTools.contains(name) else { return "step \(index + 1): tool must be one of \(stepTools.joined(separator: ", "))" }
    if rest["app"] != nil { return "step \(index + 1): app is given once, outside the steps" }
    var withApp = rest
    withApp["app"] = "-"
    if let found = validateArguments(name, withApp) ?? missingPlace(name, rest) { return "step \(index + 1) (\(name)): \(found)" }
  }
  return nil
}
