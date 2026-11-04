// What the helper knows about well-known apps: ready operations through each app's official automation
// surface, hints for working in its window, and known pitfalls. See docs/app-knowledge.md.

import AppKit

enum ArgumentKind: String {
  case string, integer, boolean
}

struct Argument {
  let name: String
  let kind: ArgumentKind
  let required: Bool
  let description: String
  var allowed: [String]? = nil
  var minimum: Int? = nil
  var maximum: Int? = nil
}

enum Effect: String {
  case reads, changes
}

struct Operation {
  let name: String
  let summary: String
  let effect: Effect
  let arguments: [Argument]
  let run: (JSON) throws -> JSON
}

struct AppKnowledge {
  let bundleId: String
  let name: String
  let summary: String
  // Shown in the approval window when the operations reach the app's data without its window.
  var access: String? = nil
  var hints: [String] = []
  var pitfalls: [String] = []
  var operations: [Operation] = []
}

let appCatalog: [AppKnowledge] = [notesKnowledge, remindersKnowledge, calendarKnowledge, settingsKnowledge, homeKnowledge]

func knowledge(forBundleId bundleId: String) -> AppKnowledge? {
  appCatalog.first { $0.bundleId == bundleId }
}

private func knowledge(matching query: String) -> AppKnowledge? {
  let lowered = query.lowercased()
  return appCatalog.first { $0.bundleId.lowercased() == lowered || $0.name.lowercased() == lowered }
}

private func describe(_ argument: Argument) -> JSON {
  var result: JSON = ["name": argument.name, "type": argument.kind.rawValue, "required": argument.required, "description": argument.description]
  if let allowed = argument.allowed { result["allowed"] = allowed }
  if let minimum = argument.minimum { result["minimum"] = minimum }
  if let maximum = argument.maximum { result["maximum"] = maximum }
  return result
}

func listOperations(_ params: JSON) throws -> JSON {
  guard let query = params["app"] as? String else {
    return ["apps": appCatalog.map { app -> JSON in
      ["app": app.name, "bundle_id": app.bundleId, "summary": app.summary, "operations": app.operations.map(\.name)]
    }]
  }
  guard let app = knowledge(matching: query) else {
    throw HelperError(code: "unknown_app", message: "There is no definition for \(query). Apps with one: \(appCatalog.map(\.name).joined(separator: ", ")).")
  }
  var result: JSON = ["app": app.name, "bundle_id": app.bundleId, "summary": app.summary]
  result["operations"] = app.operations.map { operation -> JSON in
    ["name": operation.name, "summary": operation.summary, "effect": operation.effect.rawValue, "arguments": operation.arguments.map(describe)]
  }
  if !app.hints.isEmpty { result["hints"] = app.hints }
  if !app.pitfalls.isEmpty { result["pitfalls"] = app.pitfalls }
  return result
}

// The lines get_window_state adds under its header for an app with a definition.
func knowledgeLines(forBundleId bundleId: String) -> [String] {
  guard let app = knowledge(forBundleId: bundleId) else { return [] }
  let operations = app.operations.isEmpty ? [] : [
    "hint: Faster than the window: run_operation (\(app.operations.map(\.name).joined(separator: ", "))). list_operations app=\"\(app.name)\" gives their arguments.",
  ]
  return operations + app.hints.map { "hint: \($0)" } + app.pitfalls.map { "pitfall: \($0)" }
}

// Refuses unknown, missing and mistyped arguments, so an operation receives only what it declares.
private func validated(_ arguments: Any?, for operation: Operation) throws -> JSON {
  let given: JSON
  if arguments == nil {
    given = [:]
  } else if let object = arguments as? JSON {
    given = object
  } else {
    throw HelperError(code: "invalid_arguments", message: "arguments must be an object.")
  }
  let declared = Dictionary(uniqueKeysWithValues: operation.arguments.map { ($0.name, $0) })
  for key in given.keys where declared[key] == nil {
    throw HelperError(code: "invalid_arguments", message: "\(operation.name) takes no argument \(key). It takes: \(operation.arguments.map(\.name).joined(separator: ", ")).")
  }
  for argument in operation.arguments {
    guard let value = given[argument.name], !(value is NSNull) else {
      if argument.required { throw HelperError(code: "invalid_arguments", message: "\(argument.name) is required.") }
      continue
    }
    switch argument.kind {
    case .string:
      guard let text = value as? String else { throw HelperError(code: "invalid_arguments", message: "\(argument.name) must be a string.") }
      if let allowed = argument.allowed, !allowed.contains(text) {
        throw HelperError(code: "invalid_arguments", message: "\(argument.name) must be one of \(allowed.joined(separator: ", ")).")
      }
    case .integer:
      guard let number = value as? Int, CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else {
        throw HelperError(code: "invalid_arguments", message: "\(argument.name) must be a whole number.")
      }
      if let minimum = argument.minimum, number < minimum { throw HelperError(code: "invalid_arguments", message: "\(argument.name) must be at least \(minimum).") }
      if let maximum = argument.maximum, number > maximum { throw HelperError(code: "invalid_arguments", message: "\(argument.name) must be at most \(maximum).") }
    case .boolean:
      guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else {
        throw HelperError(code: "invalid_arguments", message: "\(argument.name) must be true or false.")
      }
    }
  }
  return given
}

// Resolves the app by its definition, then passes the same gate as every other tool. The operation is looked
// up in that app's catalog only, so approving one app never reaches another's operations.
func runOperation(_ params: JSON, session: ApprovalSession, connection: Connection) throws -> JSON {
  let query = try string(params, "app")
  let name = try string(params, "operation")
  guard let app = knowledge(matching: query) else {
    throw HelperError(code: "unknown_app", message: "There is no definition for \(query). Use list_operations.")
  }
  guard let operation = app.operations.first(where: { $0.name == name }) else {
    let names = app.operations.map(\.name)
    throw HelperError(code: "unknown_operation", message: "\(app.name) has no operation \(name)." + (names.isEmpty ? " It has hints only." : " It has: \(names.joined(separator: ", "))."))
  }
  let arguments = try validated(params["arguments"], for: operation)
  let target = try operationTarget(app)
  try ApprovalGate.require(target, session: session, connection: connection)
  try connection.throwIfCancelled()

  let frontBefore = onMain { NSWorkspace.shared.frontmostApplication }
  var result: JSON
  do {
    result = try operation.run(arguments)
  } catch let error as HelperError where error.code == "timeout" && operation.effect == .changes {
    throw HelperError(code: "outcome_unknown", message: "\(error.message) The change may have been made. Read the state before trying again.")
  }
  if returnFocus(to: frontBefore, fromBundleId: app.bundleId, wasRunning: target.pid > 0) { result["focus_returned"] = true }
  result["operation"] = operation.name
  return result
}

// The running app when there is one, since that is the process the signer is checked on; otherwise the
// installed bundle, because operations do not need the app to run.
private func operationTarget(_ app: AppKnowledge) throws -> AppIdentity {
  let running = onMain { NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId).first { !$0.isTerminated } }
  if let running {
    return AppIdentity(pid: running.processIdentifier, bundleId: app.bundleId, name: running.localizedName ?? app.name, launchDate: running.launchDate, path: running.bundleURL?.path)
  }
  guard let url = onMain({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId) }) else {
    throw HelperError(code: "app_not_found", message: "\(app.name) is not installed.")
  }
  return AppIdentity(pid: 0, bundleId: app.bundleId, name: app.name, launchDate: nil, path: url.path)
}

private let launchWatchChecks = 10
private let launchWatchInterval = 0.1

// An app that a script launched or woke may come forward; the app the user was in gets the focus back. An app
// that was already running is checked once. One that the operation started can come forward a moment after the
// script has returned, so it is watched for a second; an operation that never started it costs nothing.
private func returnFocus(to previous: NSRunningApplication?, fromBundleId bundleId: String, wasRunning: Bool) -> Bool {
  guard let previous, previous.bundleIdentifier != bundleId, !previous.isTerminated else { return false }
  let bringBack = {
    onMain {
      guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId else { return false }
      return previous.activate()
    }
  }
  let startedNow = !wasRunning && onMain { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty }
  guard startedNow else { return bringBack() }
  var returned = false
  for _ in 0..<launchWatchChecks {
    returned = bringBack() || returned
    sleep(seconds: launchWatchInterval)
  }
  return returned
}

// MARK: Shared argument helpers

func optionalString(_ arguments: JSON, _ key: String) -> String? {
  guard let text = arguments[key] as? String, !text.isEmpty else { return nil }
  return text
}

func limit(_ arguments: JSON, default value: Int = 20) -> Int {
  arguments["limit"] as? Int ?? value
}

let limitArgument = Argument(name: "limit", kind: .integer, required: false, description: "Most items to return; default 20", minimum: 1, maximum: 200)
