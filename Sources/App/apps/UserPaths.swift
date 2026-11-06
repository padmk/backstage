// The one rule for which files operations may touch, shared by every app that takes a path.

import Foundation

// The home folder as the file system names it, for checks of resolved paths.
let resolvedHome = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path

func isReachablePath(_ path: String) -> Bool {
  (path.hasPrefix(resolvedHome + "/") && path != resolvedHome) || path.hasPrefix("/Volumes/")
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
    throw HelperError(code: "not_allowed", message: "Only files in your home folder or on external volumes are reachable.")
  }
  if mustExist, (try? FileManager.default.attributesOfItem(atPath: path)) == nil { throw HelperError(code: "not_found", message: "\(path) does not exist.") }
  return url
}
