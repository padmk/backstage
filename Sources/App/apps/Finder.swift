// Finder for what a shell cannot see: what the user has selected, the folder in front, revealing a file, tags,
// and moving to the Trash in a way the user can put back. Other file work belongs to the shell.

import Foundation

private let target = "Finder"

private func paths(_ urls: Any) -> [String] {
  (urls as? [String] ?? []).compactMap { URL(string: $0)?.path }
}

private let selection = Operation(name: "selection", summary: "List the files selected in the front Finder window", effect: .reads, arguments: []) { _ in
  let urls = try runScript("return Application('Finder').selection().map((item) => item.url());", target: target)
  return ["paths": paths(urls)]
}

private let frontFolder = Operation(name: "front_folder", summary: "The folder shown in the front Finder window, or the Desktop", effect: .reads, arguments: []) { _ in
  let url = try runScript("return Application('Finder').insertionLocation().url();", target: target)
  return ["path": paths([url]).first ?? ""]
}

private let reveal = Operation(
  name: "reveal", summary: "Show a file selected in a Finder window, behind the app you are in", effect: .changes,
  arguments: [Argument(name: "path", kind: .string, required: true, description: "Absolute path, or one starting with ~")]
) { arguments in
  let url = try userPath(arguments)
  let urls = try runScript("const Finder = Application('Finder'); Finder.reveal(Path(args.path)); delay(0.3); return Finder.selection().map((item) => item.url());",
                           arguments: ["path": url.path], target: target)
  return ["path": url.path, "verified": paths(urls).contains { URL(fileURLWithPath: $0).standardizedFileURL.path == url.path }]
}

private let getTags = Operation(
  name: "get_tags", summary: "Read a file's Finder tags", effect: .reads,
  arguments: [Argument(name: "path", kind: .string, required: true, description: "Absolute path, or one starting with ~")]
) { arguments in
  let url = try userPath(arguments)
  return ["path": url.path, "tags": try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []]
}

private let setTags = Operation(
  name: "set_tags", summary: "Replace a file's Finder tags", effect: .changes,
  arguments: [
    Argument(name: "path", kind: .string, required: true, description: "Absolute path, or one starting with ~"),
    Argument(name: "tags", kind: .string, required: true, description: "Tag names separated by commas; empty removes every tag"),
  ]
) { arguments in
  let url = try userPath(arguments)
  let tags = try string(arguments, "tags").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
  var fresh = url
  fresh.removeAllCachedResourceValues()
  let saved = try fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
  return ["path": url.path, "tags": saved, "verified": saved == tags]
}

private let trash = Operation(
  name: "trash", summary: "Move a file or folder to the Trash, where the user can put it back", effect: .changes,
  arguments: [Argument(name: "path", kind: .string, required: true, description: "Absolute path, or one starting with ~")]
) { arguments in
  let url = try userPath(arguments)
  // Finder asks for an administrator password to trash a symbolic link and then fails, so a link goes to the
  // Trash directly. Everything else goes through Finder, which records where it came from for Put Back.
  let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  var trashed: Any = ""
  if isLink {
    var location: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &location)
    trashed = location?.absoluteString ?? ""
  } else {
    trashed = try runScript("return Application('Finder').delete(Path(args.path)).url();", arguments: ["path": url.path], target: target)
  }
  let gone = (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil
  var result: JSON = ["path": url.path, "verified": gone]
  if let location = paths([trashed]).first { result["trashed_as"] = location }
  return result
}

let finderKnowledge = AppKnowledge(
  bundleId: "com.apple.finder", name: "Finder", scripted: true, summary: "Read the selection and front folder, reveal files, set tags, move to the Trash",
  access: "Can also reach your files through Finder.",
  pitfalls: [
    "For reading, copying or moving files, use a shell; these operations cover what only Finder knows.",
    "Only files in the home folder or on external volumes are reachable.",
    "reveal opens a Finder window if none shows the file; it stays behind the app you are in.",
  ],
  operations: [selection, frontFolder, reveal, getTags, setTags, trash])
