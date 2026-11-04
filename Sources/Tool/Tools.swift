// The MCP tools and their argument checks. Bad arguments stop here, before any request reaches an app.

import Foundation

typealias JSON = [String: Any]

private let app: JSON = ["type": "string", "description": "App name, bundle id or pid"]
private let window: JSON = ["type": "integer", "minimum": 0, "description": "Window index shown in get_window_state; default the first"]
private let element: JSON = ["type": "integer", "minimum": 1, "description": "Element number from get_window_state"]

private func described(_ rule: JSON, _ description: String) -> JSON {
  var copy = rule
  copy["description"] = description
  return copy
}

// Tools that only read say so, so a client can allow or batch them; the others act on apps.
private let reads: JSON = ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false]
private let acts: JSON = ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false]

struct ToolDefinition {
  let name: String
  let description: String
  let properties: [(String, JSON)]
  let required: [String]
  let annotations: JSON

  var inputSchema: JSON {
    ["type": "object", "properties": Dictionary(uniqueKeysWithValues: properties), "required": required, "additionalProperties": false]
  }

  var listed: JSON {
    var entry: JSON = ["name": name, "description": description, "inputSchema": inputSchema]
    if !annotations.isEmpty { entry["annotations"] = annotations }
    return entry
  }

  func rule(for key: String) -> JSON? { properties.first { $0.0 == key }?.1 }
}

// The apps with ready operations, kept in step with the app's catalog (Sources/App/apps/Catalog.swift), so an agent
// can go straight to list_operations for one of them.
private let appsWithOperations = "Notes, Reminders, Calendar, Contacts, Mail, Messages, Finder, Pages, Numbers, Music, Shortcuts and System Settings"

// The tools run_actions can run as steps, with their own arguments except app.
let stepTools = ["press", "set_value", "type_text", "select_text", "press_key", "scroll", "drag", "click_at"]
let maxSteps = 20

let tools: [ToolDefinition] = [
  ToolDefinition(
    name: "list_apps",
    description: "List running apps. Needs no approval.",
    properties: [
      
    ],
    required: [], annotations: [:]),
  ToolDefinition(
    name: "launch_app",
    description: "Start an app in the background. If it takes the focus while starting, the app you were in gets it back and the new app stays behind it. An app that is already running is left as it is.",
    properties: [
      ("app", ["type": "string", "description": "App name or bundle id, not a path"] as JSON)
    ],
    required: ["app"], annotations: [:]),
  ToolDefinition(
    name: "list_operations",
    description: "List the ready operations, hints and pitfalls Backstage knows for well-known apps. Without app: the apps that have them. With app: its operations and their arguments. Prefer an operation to working through the window: it is faster, runs in the background and checks its own result. Needs no approval.",
    properties: [
      ("app", ["type": "string", "description": "App name or bundle id"] as JSON)
    ],
    required: [], annotations: [:]),
  ToolDefinition(
    name: "run_operation",
    description: "Run one operation from list_operations. The reply carries the result and, for a change, `verified`. `outcome_unknown` means the change may have been made: read the state before trying again.",
    properties: [
      ("app", ["type": "string", "description": "App name or bundle id"] as JSON),
      ("operation", ["type": "string", "description": "Operation name from list_operations, such as create"] as JSON),
      ("arguments", ["type": "object", "description": "The operation's arguments, as list_operations describes them"] as JSON)
    ],
    required: ["app", "operation"], annotations: [:]),
  ToolDefinition(
    name: "get_window_state",
    description: "Read a window as lines of numbered elements with their state and actions. The first line lists the app's windows. Numbers stay valid across reads in this session.",
    properties: [
      ("app", ["type": "string", "description": "App name, bundle id or pid"] as JSON),
      ("window", ["type": "integer", "minimum": 0, "description": "Window index shown in get_window_state; default the first"] as JSON),
      ("menu_bar", ["type": "boolean", "description": "Read the menu bar instead of a window"] as JSON),
      ("menu_extras", ["type": "boolean", "description": "Read the app's items on the right of the menu bar, such as status icons, instead of a window"] as JSON),
      ("root", ["type": "integer", "minimum": 1, "description": "Read only this element's subtree"] as JSON),
      ("max_elements", ["type": "integer", "minimum": 1, "maximum": 5000] as JSON)
    ],
    required: ["app"], annotations: [:]),
  ToolDefinition(
    name: "screenshot",
    description: "Capture a window as a PNG, one image pixel per window point, so its coordinates work with click_at.",
    properties: [
      ("app", ["type": "string", "description": "App name, bundle id or pid"] as JSON),
      ("window", ["type": "integer", "minimum": 0, "description": "Window index shown in get_window_state; default the first"] as JSON)
    ],
    required: ["app"], annotations: [:]),
  ToolDefinition(
    name: "press",
    description: "Press an element without taking focus, or run one of the actions it lists. The reply's `state` reports what changed in the area last read, or `unknown` when it cannot tell; `verified: false` means delivery could not be confirmed.",
    properties: [
      ("app", ["type": "string", "description": "App name, bundle id or pid"] as JSON),
      ("element", ["type": "integer", "minimum": 1, "description": "Element number from get_window_state"] as JSON),
      ("action", ["type": "string", "description": "An action the element lists, such as ShowMenu. Default: press"] as JSON)
    ],
    required: ["app", "element"], annotations: [:]),
  ToolDefinition(
    name: "set_value",
    description: "Replace the value of an editable element.",
    properties: [
      ("app", ["type": "string", "description": "App name, bundle id or pid"] as JSON),
      ("element", ["type": "integer", "minimum": 1, "description": "Element number from get_window_state"] as JSON),
      ("value", ["type": "string"] as JSON)
    ],
    required: ["app", "element", "value"], annotations: [:]),
  ToolDefinition(
    name: "type_text",
    description: "Insert text at an element, or without one send it as keys to the app's focused element. Delivery `value_appended_at_end` means an unfocused one-line field took it at its end, ignoring the cursor. Line breaks and tabs need an element that takes text directly; otherwise send them with press_key. Nothing is typed if the element cannot take it.",
    properties: [
      ("app", ["type": "string", "description": "App name, bundle id or pid"] as JSON),
      ("text", ["type": "string", "maxLength": 100000] as JSON),
      ("element", ["type": "integer", "minimum": 1, "description": "Element number from get_window_state"] as JSON)
    ],
    required: ["app", "text"], annotations: [:]),
  ToolDefinition(
    name: "press_key",
    description: "Send a key or combination, such as return or cmd+s, to the app in the background. A native view receives it once it has focus, so click the view with click_at first. Other apps and combinations may behave differently, so check the effect, and prefer pressing the menu item.",
    properties: [
      ("app", ["type": "string", "description": "App name, bundle id or pid"] as JSON),
      ("key", ["type": "string", "maxLength": 64] as JSON)
    ],
    required: ["app", "key"], annotations: [:]),
  ToolDefinition(
    name: "scroll",
    description: "Scroll the area containing an element.",
    properties: [
      ("app", ["type": "string", "description": "App name, bundle id or pid"] as JSON),
      ("element", ["type": "integer", "minimum": 1, "description": "Element number from get_window_state"] as JSON),
      ("direction", ["type": "string", "enum": ["up", "down", "left", "right"]] as JSON),
      ("pages", ["type": "integer", "minimum": 1, "maximum": 20] as JSON)
    ],
    required: ["app", "element", "direction"], annotations: [:]),
  ToolDefinition(
    name: "drag",
    description: "Drag from one place to another in the background, without moving the cursor: a slider's knob, an item onto a target, a selection. Each end is an element number or a point in window coordinates. Check the effect in `state` or with a screenshot.",
    properties: [
      ("app", ["type": "string", "description": "App name, bundle id or pid"] as JSON),
      ("window", ["type": "integer", "minimum": 0, "description": "Window index shown in get_window_state; default the first"] as JSON),
      ("from_element", ["type": "integer", "minimum": 1, "description": "Element to drag from, at its center"] as JSON),
      ("from_x", ["type": "number", "minimum": 0] as JSON),
      ("from_y", ["type": "number", "minimum": 0] as JSON),
      ("to_element", ["type": "integer", "minimum": 1, "description": "Element to drag to, at its center"] as JSON),
      ("to_x", ["type": "number", "minimum": 0] as JSON),
      ("to_y", ["type": "number", "minimum": 0] as JSON)
    ],
    required: ["app"], annotations: [:]),
  ToolDefinition(
    name: "click_at",
    description: "Send a click at a point in window coordinates, in the background and without moving the cursor. Use it only when no element can do the job, and check the effect, for example with a screenshot.",
    properties: [
      ("app", ["type": "string", "description": "App name, bundle id or pid"] as JSON),
      ("x", ["type": "number", "minimum": 0] as JSON),
      ("y", ["type": "number", "minimum": 0] as JSON),
      ("window", ["type": "integer", "minimum": 0, "description": "Window index shown in get_window_state; default the first"] as JSON),
      ("count", ["type": "integer", "minimum": 1, "maximum": 3] as JSON),
      ("foreground", ["type": "boolean", "description": "Last resort when a background click did not land: the window comes forward for the click, then the previous app gets the focus back and the cursor returns. Tell the user you used it."] as JSON)
    ],
    required: ["app", "x", "y"], annotations: [:]),
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
