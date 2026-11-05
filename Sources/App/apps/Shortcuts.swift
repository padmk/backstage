// Shortcuts through the `shortcuts` command, which runs a shortcut without opening the app. A shortcut can
// do anything its actions allow, which is why the approval window warns that Shortcuts reaches far.

import Foundation

private let command = "/usr/bin/shortcuts"
private let target = "Shortcuts"
private let runSeconds: TimeInterval = 120
private let maxOutput = 50000

private func installedShortcuts(folder: String?) throws -> [(name: String, id: String)] {
  // The command lists every shortcut when it does not know the folder, so the folder is checked first.
  if let folder {
    let folders = try runProcess(command, ["list", "--folders"], target: target, timeout: 30)
    guard folders.output.split(separator: "\n").contains(where: { $0 == folder }) else {
      throw HelperError(code: "not_found", message: "There is no folder named \(folder).")
    }
  }
  // The `=` form keeps a folder name that starts with a dash from being read as an option.
  let finished = try runProcess(command, ["list", "--show-identifiers"] + (folder.map { ["--folder-name=\($0)"] } ?? []), target: target, timeout: 30)
  guard finished.status == 0 else {
    throw HelperError(code: "action_failed", message: "Shortcuts could not list \(folder.map { "the folder \($0)" } ?? "its shortcuts"): \(finished.errors.prefix(300))")
  }
  return finished.output.split(separator: "\n").compactMap { line in
    guard let match = line.range(of: #" \(([0-9A-F-]{36})\)$"#, options: .regularExpression) else { return nil }
    return (String(line[..<match.lowerBound]), String(line[match].dropFirst(2).dropLast()))
  }
}

private let list = Operation(
  name: "list", summary: "List shortcuts with their ids", effect: .reads,
  arguments: [Argument(name: "folder", kind: .string, required: false, description: "Folder name; default every shortcut")]
) { arguments in
  ["shortcuts": try installedShortcuts(folder: optionalString(arguments, "folder")).map { ["name": $0.name, "id": $0.id] as JSON }]
}

private let run = Operation(
  name: "run", summary: "Run a shortcut, optionally with text as its input, and return its output as text", effect: .changes,
  arguments: [
    Argument(name: "shortcut", kind: .string, required: true, description: "Shortcut id from list, or its exact name"),
    Argument(name: "input", kind: .string, required: false, description: "Text given to the shortcut as its input"),
  ]
) { arguments in
  let query = try string(arguments, "shortcut")
  let all = try installedShortcuts(folder: nil)
  let matches = all.filter { $0.id == query }.isEmpty ? all.filter { $0.name == query } : all.filter { $0.id == query }
  guard let shortcut = matches.first else { throw HelperError(code: "not_found", message: "There is no shortcut \(query). Use list.") }
  guard matches.count == 1 else { throw HelperError(code: "ambiguous", message: "Several shortcuts are named \(query). Give its id.") }

  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shortcut-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: folder) }
  let outputFile = folder.appendingPathComponent("output.txt")
  var options = ["run", shortcut.id, "--output-path", outputFile.path, "--output-type", "public.plain-text"]
  if let input = arguments["input"] as? String {
    let inputFile = folder.appendingPathComponent("input.txt")
    try Data(input.utf8).write(to: inputFile)
    options += ["--input-path", inputFile.path]
  }
  let finished = try runProcess(command, options, target: "The shortcut \(shortcut.name)", timeout: runSeconds)
  guard finished.status == 0 else {
    throw HelperError(code: "action_failed", message: "The shortcut \(shortcut.name) stopped with an error: \(finished.errors.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))")
  }
  var result: JSON = ["shortcut": shortcut.name, "id": shortcut.id, "finished": true]
  if let data = FileManager.default.contents(atPath: outputFile.path) {
    let text = String(decoding: data, as: UTF8.self)
    result["output"] = String(text.prefix(maxOutput))
    if text.count > maxOutput { result["output_truncated"] = true }
  }
  return result
}

let shortcutsKnowledge = AppKnowledge(
  bundleId: "com.apple.shortcuts", name: "Shortcuts", summary: "List and run shortcuts, which also reach Home scenes and other apps without scripting",
  access: "Run your shortcuts, which may do anything their actions do",
  pitfalls: [
    "A shortcut does whatever its actions do, and Backstage cannot check its effect; read the state it was meant to change.",
    "A shortcut that asks a question or shows a result opens a dialog, which can come to the front.",
    "A run that times out may have done part of its work.",
  ],
  operations: [list, run])
