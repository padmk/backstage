// The one rule for which files operations may touch, shared by every app that takes a path.

import Foundation

// The home folder as the file system names it, for checks of resolved paths.
let resolvedHome = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path

// Library holds other apps' data, which macOS guards per app; with Full Disk Access, which the WhatsApp operations
// need, nothing else would, so only iCloud Drive and cloud storage folders in it are reachable.
private func reachableFolders(inLibrary library: String) -> [String] {
  ["/Mobile Documents/", "/CloudStorage/"].map { library + $0 }
}

// The rule on a path as the file system names it, with links resolved; `home` is the resolved home folder.
func isReachablePath(_ path: String, home: String = resolvedHome) -> Bool {
  let library = home + "/Library"
  if path == library || path.hasPrefix(library + "/") { return reachableFolders(inLibrary: library).contains { path.hasPrefix($0) } }
  if path.hasPrefix(home + "/") { return true }
  return path.hasPrefix("/Volumes/") && !holdsAnotherLibraryOrBackup(path)
}

// Another volume can hold a copy of a home folder, such as a mounted system's Data volume, or Time Machine's
// backups: their Library folders and backup trees are refused whole.
private let anotherLibraryOrBackup = #"/(users/[^/]+/library|backups\.backupdb|\.timemachine)(/|$)"#

private func holdsAnotherLibraryOrBackup(_ path: String) -> Bool {
  path.range(of: anotherLibraryOrBackup, options: [.regularExpression, .caseInsensitive]) != nil
}

// A path an operation may report: one in the reachable set, links resolved; nil for anything else, so a listing
// does not reveal files outside it.
func reportablePath(_ path: String) -> String? { reportablePath(path, home: resolvedHome) }

func reportablePath(_ path: String, home: String) -> String? {
  guard path.hasPrefix("/") else { return nil }
  let resolved = resolvingExistingFolders(URL(fileURLWithPath: path).standardizedFileURL).path
  return isReachablePath(resolved, home: home) ? path : nil
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

// An existing entry under the name the file system keeps for it, without following a link: a volume that ignores
// case also finds ~/LIBRARY, which must meet the rule as Library. (File URLs give every name in one Unicode form; the
// folders above it come resolved, which gives them their names on disk.) Only an entry that is not there keeps the
// name as given; one whose name cannot be read is refused, as permission_missing when macOS keeps the helper out,
// since the rule cannot be checked on it.
private func onDiskName(_ url: URL, home: String) throws -> URL {
  let given = url.lastPathComponent
  let stored: String
  do {
    stored = try url.resourceValues(forKeys: [.nameKey]).name ?? given
  } catch {
    if try !entryExists(url.path, home: home) { return url }
    throw HelperError(code: "not_allowed", message: "The name \(url.path) has on disk cannot be read, so it cannot be checked against the rule for which files are reachable.")
  }
  guard stored != given, stored.compare(given, options: [.caseInsensitive]) == .orderedSame else { return url }
  return url.deletingLastPathComponent().appendingPathComponent(stored)
}

// The folder macOS guards as a whole that holds a path, such as Documents, iCloud Drive or a volume, to name it
// when macOS keeps the helper out.
private func guardedFolder(of path: String, home: String) -> String {
  guard let base = [home, "/Volumes"].first(where: { path.hasPrefix($0 + "/") }) else { return (path as NSString).deletingLastPathComponent }
  let depth = path.hasPrefix(home + "/Library/") ? 2 : 1
  let parts = path.dropFirst(base.count).split(separator: "/").prefix(depth)
  return ([base] + parts.map(String.init)).joined(separator: "/")
}

// Whether something exists at a path, without following a final link. A path macOS keeps from the helper, such as
// a file in Documents before the user allows it, fails with permission_missing rather than passing for missing.
func entryExists(_ path: String, home: String = resolvedHome) throws -> Bool {
  var status = stat()
  guard lstat(path, &status) != 0 else { return true }
  guard [EPERM, EACCES].contains(errno) else { return false }
  let folder = guardedFolder(of: path, home: home)
  throw HelperError(code: "permission_missing", message: "macOS does not let Backstage reach \(folder). Ask the user to allow Backstage access to it in System Settings > Privacy & Security > Files and Folders, then try again.")
}

// Only the user's own files and external volumes; the home folder itself and anything else are refused. With
// followingLink, a link is checked by where it leads, for operations that open what it points to; otherwise the
// link itself is acted on, so only its folder is resolved.
func userPath(_ arguments: JSON, key: String = "path", mustExist: Bool = true, followingLink: Bool = false, home: String = resolvedHome) throws -> URL {
  let text = try string(arguments, key)
  let expanded = (text as NSString).expandingTildeInPath
  guard expanded.hasPrefix("/") else { throw HelperError(code: "invalid_arguments", message: "\(key) must be absolute or start with ~.") }
  let given = URL(fileURLWithPath: expanded).standardizedFileURL
  let url = followingLink
    ? resolvingExistingFolders(given)
    : try onDiskName(resolvingExistingFolders(given.deletingLastPathComponent()).appendingPathComponent(given.lastPathComponent), home: home)
  let path = url.path
  guard isReachablePath(path, home: home) else {
    throw HelperError(code: "not_allowed", message: "Only files in your home folder, outside Library except iCloud Drive and cloud storage, or on external volumes are reachable.")
  }
  if mustExist, try !entryExists(path, home: home) { throw HelperError(code: "not_found", message: "\(path) does not exist.") }
  return url
}

// The kinds of copies Backstage hands agents, each under a folder of its own in the system's temporary folder.
enum CopyFolder: String, CaseIterable {
  case audioRecordings = "audio-recordings", messagesAttachments = "messages-attachments"
  case whatsAppMedia = "whatsapp-media", photosExport = "photos-export"
}

private let resolvedTemporaryFolder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path

// A new private folder for one copy an operation hands the agent, such as an attachment it cannot read where the app
// keeps it: under the system's temporary folder, readable only by the user, so nothing is replaced and no other copy
// is reached through it. macOS clears the temporary folder over time.
func newCopyFolder(_ kind: CopyFolder) throws -> URL {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(kind.rawValue, isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  do {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  } catch {
    throw HelperError(code: "action_failed", message: "No folder for the copy could be made: \(error.localizedDescription)")
  }
  return folder
}

// A file an allowed app may be handed: one of the user's own reachable files, or a copy Backstage made, such as a
// recording, with links resolved.
func openableFile(_ text: String) throws -> URL { try openableFile(text, home: resolvedHome) }

func openableFile(_ text: String, home: String) throws -> URL {
  let expanded = (text as NSString).expandingTildeInPath
  guard expanded.hasPrefix("/") else { throw HelperError(code: "invalid_arguments", message: "Each file must be absolute or start with ~.") }
  let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
  let path = url.path
  let isCopy = CopyFolder.allCases.contains { path.hasPrefix("\(resolvedTemporaryFolder)/\($0.rawValue)/") }
  guard isReachablePath(path, home: home) || isCopy else {
    throw HelperError(code: "not_allowed", message: "\(text) is not reachable: only files in your home folder, outside Library except iCloud Drive and cloud storage, on external volumes, or copies Backstage made can be opened.")
  }
  var isFolder: ObjCBool = false
  guard try entryExists(path, home: home), FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue else {
    throw HelperError(code: "not_found", message: "\(text) is not a file.")
  }
  return url
}
