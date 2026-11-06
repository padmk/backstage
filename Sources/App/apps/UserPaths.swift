// The one rule for which files operations may touch, shared by every app that takes a path.

import Foundation

// The home folder as the file system names it, for checks of resolved paths.
let resolvedHome = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path

// Library holds other apps' data, which macOS guards per app; with Full Disk Access, which the WhatsApp operations
// need, nothing else would, so only iCloud Drive and cloud storage folders in it are reachable.
let libraryFolder = resolvedHome + "/Library"
let reachableInLibrary = ["/Mobile Documents/", "/CloudStorage/"].map { libraryFolder + $0 }

func isReachablePath(_ path: String) -> Bool {
  if path == libraryFolder || path.hasPrefix(libraryFolder + "/") { return reachableInLibrary.contains { path.hasPrefix($0) } }
  return (path.hasPrefix(resolvedHome + "/") && path != resolvedHome) || path.hasPrefix("/Volumes/")
}

// A path an operation may report: one in the reachable set, links resolved; nil for anything else, so a listing
// does not reveal files outside it.
func reportablePath(_ path: String) -> String? {
  guard !path.isEmpty else { return nil }
  let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  return isReachablePath(resolved) ? path : nil
}

// Resolves links in the deepest folder that exists, since resolving skips a path that does not exist and a
// missing folder under /Volumes could otherwise hide a link to the system disk.
private func resolvingExistingFolders(_ url: URL) -> URL {
  var existing = url
  var rest: [String] = []
  while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
    rest.insert(existing.lastPathComponent, at: 0)
    existing.deleteLastPathComponent()
  }
  return rest.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
}

// Only the user's own files and external volumes; the home folder itself and anything else are refused. With
// followingLink, a link is checked by where it leads, for operations that open what it points to; otherwise the
// link itself is acted on, so only its folder is resolved.
func userPath(_ arguments: JSON, key: String = "path", mustExist: Bool = true, followingLink: Bool = false) throws -> URL {
  let text = try string(arguments, key)
  let expanded = (text as NSString).expandingTildeInPath
  guard expanded.hasPrefix("/") else { throw HelperError(code: "invalid_arguments", message: "\(key) must be absolute or start with ~.") }
  let given = URL(fileURLWithPath: expanded).standardizedFileURL
  let url = followingLink
    ? resolvingExistingFolders(given)
    : resolvingExistingFolders(given.deletingLastPathComponent()).appendingPathComponent(given.lastPathComponent)
  let path = url.path
  guard isReachablePath(path) else {
    throw HelperError(code: "not_allowed", message: "Only files in your home folder, outside Library except iCloud Drive and cloud storage, or on external volumes are reachable.")
  }
  if mustExist, (try? FileManager.default.attributesOfItem(atPath: path)) == nil { throw HelperError(code: "not_found", message: "\(path) does not exist.") }
  return url
}

// A new private folder for one copy an operation hands the agent, such as an attachment it cannot read where the app
// keeps it: under the system's temporary folder, readable only by the user, so nothing is replaced and no other copy
// is reached through it. macOS clears the temporary folder over time.
func newCopyFolder(_ kind: String) throws -> URL {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(kind, isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  do {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  } catch {
    throw HelperError(code: "action_failed", message: "No folder for the copy could be made: \(error.localizedDescription)")
  }
  return folder
}
