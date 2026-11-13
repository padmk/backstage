// Hands an MCP session over to the installed command after an update, so the client keeps its connection.
// The running command replaces itself with the new one (exec), keeping stdin and stdout. The new one gets what the
// session needs through a file descriptor: the client's name, the tool list it was given, which handoff this is,
// and the input not yet handled (the requests never sent to the helper, and a line not yet complete).

import Foundation
import HelperLink

// Read from the descriptor named by the resume argument before stdin.
struct HandoffState {
  var clientName: String?
  var toolsDigest: String
  // How many handoffs this session has been through; element numbers start in a range of their own after each.
  var generation: Int
  // The other Macs the session reached; their connections close in a handoff, so the next call there says so.
  var computers: [String]
  // Added to every element number, for a session another Mac's command opened again (see RemoteComputers).
  var elementNumberBase = 0
}

let resumeArgument = "--resume-fd"
private let maxResumeBytes = 64 << 20

// The installed bundle can take a session only when it declares the same handoff revision as this command.
func installedCommandTakesHandoff() -> Bool {
  let info = NSDictionary(contentsOfFile: installedAppPath + "/Contents/Info.plist")
  return info?[Product.sessionHandoffKey] as? Int == Product.sessionHandoffRevision
    && FileManager.default.isExecutableFile(atPath: installedCommandPath)
}

// A digest of the tool list as the client saw it, so the new command can tell whether it changed.
func toolsDigest() -> String {
  var hash: UInt64 = 14_695_981_039_346_656_037
  for byte in jsonLine(tools.map(\.listed)) { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
  return String(hash, radix: 16)
}

// Writes the state and the input to an unlinked private file and execs the installed command with it. Returns only
// when that fails, leaving this process as it was.
func execInstalledCommand(state: HandoffState, input: Data, directories: Directories) -> Bool {
  guard (try? ensurePrivateDirectory(directories.state)) != nil else { return false }
  let template = directories.state + "/handoff.XXXXXX"
  var path = Array(template.utf8CString)
  let descriptor = mkstemp(&path)
  guard descriptor >= 0 else { return false }
  unlink(path)
  var header: JSON = ["tools_digest": state.toolsDigest, "generation": state.generation]
  if let name = state.clientName { header["client_name"] = name }
  if !state.computers.isEmpty { header["computers"] = state.computers }
  if state.elementNumberBase > 0 { header["element_number_base"] = state.elementNumberBase }
  var contents = jsonLine(header)
  contents.append(input)
  // The new command reads at most this much, so more would lose input; the session stays here instead.
  guard contents.count <= maxResumeBytes, writeAll(descriptor, contents), lseek(descriptor, 0, SEEK_SET) == 0 else {
    close(descriptor)
    return false
  }
  var attributes: posix_spawnattr_t?
  var actions: posix_spawn_file_actions_t?
  posix_spawnattr_init(&attributes)
  posix_spawn_file_actions_init(&actions)
  defer {
    posix_spawnattr_destroy(&attributes)
    posix_spawn_file_actions_destroy(&actions)
  }
  // Only stdin, stdout, stderr and the state cross over: the helper's socket and anything else close. The signal
  // mask and the ignored signals of this process would cross over too, so both start clean.
  posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
  var none = sigset_t()
  sigemptyset(&none)
  posix_spawnattr_setsigmask(&attributes, &none)
  var defaults = sigset_t()
  sigemptyset(&defaults)
  for signalNumber in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&defaults, signalNumber) }
  posix_spawnattr_setsigdefault(&attributes, &defaults)
  for kept in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO, descriptor] { posix_spawn_file_actions_addinherit_np(&actions, kept) }
  let arguments = [installedCommandPath, "mcp", resumeArgument, String(descriptor)]
  let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
  defer { argv.forEach { free($0) } }
  var pid: pid_t = 0
  _ = posix_spawn(&pid, installedCommandPath, &actions, &attributes, argv, environ)
  close(descriptor)
  return false
}

// The state and the input a handoff left, read once at start.
func readResume(arguments: [String]) -> (HandoffState, Data)? {
  guard let index = arguments.firstIndex(of: resumeArgument), index + 1 < arguments.count,
    let descriptor = Int32(arguments[index + 1]) else { return nil }
  defer { close(descriptor) }
  var contents = Data()
  var buffer = [UInt8](repeating: 0, count: 65536)
  while contents.count < maxResumeBytes {
    let count = Darwin.read(descriptor, &buffer, buffer.count)
    if count < 0, errno == EINTR { continue }
    guard count > 0 else { break }
    contents.append(contentsOf: buffer[0..<count])
  }
  guard let end = contents.firstIndex(of: 0x0A),
    let header = try? JSONSerialization.jsonObject(with: contents[contents.startIndex..<end]) as? JSON else { return nil }
  let state = HandoffState(clientName: header["client_name"] as? String, toolsDigest: header["tools_digest"] as? String ?? "",
                           generation: header["generation"] as? Int ?? 1, computers: header["computers"] as? [String] ?? [],
                           elementNumberBase: max(0, header["element_number_base"] as? Int ?? 0))
  return (state, Data(contents[contents.index(after: end)...]))
}
