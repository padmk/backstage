// The one rule for which files operations may touch, shared by every app that takes a path.

import Foundation

// Only the user's own files and external volumes; the home folder itself and anything else are refused.
func userPath(_ arguments: JSON, key: String = "path", mustExist: Bool = true) throws -> URL {
  let text = try string(arguments, key)
  let expanded = (text as NSString).expandingTildeInPath
  guard expanded.hasPrefix("/") else { throw HelperError(code: "invalid_arguments", message: "\(key) must be absolute or start with ~.") }
  // The folder is resolved, the item itself is not, so a link is acted on rather than what it points to.
  let given = URL(fileURLWithPath: expanded).standardizedFileURL
  let url = given.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(given.lastPathComponent)
  let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
  let path = url.path
  guard (path.hasPrefix(home + "/") && path != home) || path.hasPrefix("/Volumes/") else {
    throw HelperError(code: "not_allowed", message: "Only files in your home folder or on external volumes are reachable.")
  }
  if mustExist, (try? FileManager.default.attributesOfItem(atPath: path)) == nil { throw HelperError(code: "not_found", message: "\(path) does not exist.") }
  return url
}
