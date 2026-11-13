// The real app, built for tests, in a temporary home with its own app list. Nothing here needs macOS permissions;
// Finder is the running app.

import Darwin
import Foundation
import HelperLink
import Testing

private let finder = "com.apple.finder"

// The app's own binary outside a bundle: it takes --home and holds no permissions.
final class RealHelper {
  let process = Process()

  init(home: TemporaryHome) throws {
    process.executableURL = URL(fileURLWithPath: appBinary)
    process.arguments = ["--background", "--home", home.path]
    var env = ProcessInfo.processInfo.environment
    env["HOME"] = home.path
    process.environment = env
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    _ = try until { FileManager.default.fileExists(atPath: home.socketPath) ? true : nil }
  }

  deinit {
    process.terminate()
    process.waitUntilExit()
  }
}

// The command as a user runs it, against the test home, with `input` typed on its stdin.
func cli(_ home: TemporaryHome, input: String? = nil, _ arguments: String...) throws -> (output: String, status: Int32) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: commandBinary)
  process.arguments = arguments
  var env = ProcessInfo.processInfo.environment
  env["HOME"] = home.path
  env["HELPER_TEST_HOME"] = home.path
  env["HELPER_NO_START"] = "1"
  process.environment = env
  let output = Pipe()
  process.standardOutput = output
  process.standardError = output
  let typed = Pipe()
  process.standardInput = input == nil ? FileHandle.nullDevice : typed
  try process.run()
  if let input {
    typed.fileHandleForWriting.write(Data(input.utf8))
    // The child may have ended already; the test checks what it printed.
    try? typed.fileHandleForWriting.close()
  }
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (String(decoding: data, as: UTF8.self), process.terminationStatus)
}

// A process that talks to the app's socket directly.
final class RawSocket {
  private let descriptor: Int32
  private let lock = NSLock()
  private var text = ""
  private var closedByHelper = false

  init(_ path: String) throws {
    descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    var noSignal: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      for (index, byte) in path.utf8.enumerated() { raw[index] = byte }
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { throw TestFailure("Could not connect to \(path)") }
    let socketDescriptor = self.descriptor
    Thread { [weak self] in
      var buffer = [UInt8](repeating: 0, count: 65536)
      while true {
        let count = read(socketDescriptor, &buffer, buffer.count)
        guard let self else { return }
        guard count > 0 else {
          self.lock.withLock { self.closedByHelper = true }
          return
        }
        let chunk = String(decoding: buffer[0..<count], as: UTF8.self)
        self.lock.withLock { self.text += chunk }
      }
    }.start()
  }

  deinit {
    shutdown(descriptor, SHUT_RDWR)
    close(descriptor)
  }

  var received: String { lock.withLock { text } }

  var ended: Bool { lock.withLock { closedByHelper } }

  // The replies so far, by their id.
  var replies: [Object] { received.split(separator: "\n").compactMap { parseLine(String($0)) } }

  func send(_ text: String) {
    let data = Array((text + "\n").utf8)
    var offset = 0
    while offset < data.count {
      let written = data[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
      if written <= 0 { return }
      offset += written
    }
  }
}

private struct Setup {
  let home = TemporaryHome()
  let helper: RealHelper
  let server: ServerProcess

  // The app with an empty list, or with the given apps added through the command line, as a user would.
  init(allowed: [String] = []) throws {
    helper = try RealHelper(home: home)
    for app in allowed {
      let added = try cli(home, "approvals", "add", app)
      #expect(added.status == 0, "could not add \(app): \(added.output)")
    }
    server = try ServerProcess(home: home)
    _ = try server.initialize("claude-code")
  }
}

// A request that got past the list reads the window, or fails later for want of Accessibility, which this build
// holds only when the process that runs the tests has it.
private func passedGate(_ result: Object) -> Bool {
  result["isError"] as? Bool != true || ["permission_missing", "window_not_found", "screen_locked"].contains { textOf(result).hasPrefix($0 + ":") }
}

private func apps(_ server: ServerProcess) throws -> [Object] {
  (parseLine(textOf(try server.call("list_apps")))?["apps"] as? [Object]) ?? []
}

@Suite struct HelperTests {
  @Test func listsRunningAppsWhateverTheListSays() throws {
    let setup = try Setup()
    #expect(try apps(setup.server).contains { $0["bundle_id"] as? String == finder })
  }

  @Test func anAppThatIsNotOnTheListIsRefusedAtOnce() throws {
    let setup = try Setup()
    let result = try setup.server.call("get_window_state", ["app": finder])
    #expect(result["isError"] as? Bool == true)
    #expect(textOf(result).range(of: #"^not_approved: Finder \(com\.apple\.finder\) is not on the user.s list"#, options: .regularExpression) != nil)
  }

  @Test(arguments: [finder, "Finder", "fInDeR"])
  func anAppGivenByNameOrBundleIdMeetsTheSameList(app: String) throws {
    let setup = try Setup()
    #expect(textOf(try setup.server.call("get_window_state", ["app": app])).hasPrefix("not_approved"))
  }

  @Test func anAppGivenByPidMeetsTheSameList() throws {
    let setup = try Setup()
    let pid = try apps(setup.server).first { $0["bundle_id"] as? String == finder }?["pid"] as? Int
    #expect(textOf(try setup.server.call("get_window_state", ["app": String(pid ?? 0)])).hasPrefix("not_approved"))
  }

  @Test(arguments: [
    ("screenshot", #"{}"#), ("press", #"{"element":1}"#), ("set_value", #"{"element":1,"value":"x"}"#),
    ("type_text", #"{"text":"x"}"#), ("press_key", #"{"key":"return"}"#), ("scroll", #"{"element":1,"direction":"down"}"#),
    ("click_at", #"{"x":1,"y":1}"#), ("drag", #"{"from_x":1,"from_y":1,"to_x":2,"to_y":2}"#),
  ])
  func eachActionNeedsTheAppOnTheList(tool: String, arguments: String) throws {
    let setup = try Setup()
    var given = parseLine(arguments)!
    given["app"] = finder
    #expect(textOf(try setup.server.call(tool, given)).hasPrefix("not_approved"))
  }

  @Test func anAppOnTheListPassesForEveryClient() throws {
    let setup = try Setup(allowed: [finder])
    let first = try setup.server.call("get_window_state", ["app": finder])
    #expect(passedGate(first), "\(textOf(first))")
    let other = try ServerProcess(home: setup.home)
    let second = try other.call("get_window_state", ["app": finder])
    #expect(passedGate(second), "\(textOf(second))")
  }

  @Test func theListDoesNotCoverAnotherApp() throws {
    let setup = try Setup(allowed: [finder])
    guard let other = try apps(setup.server).first(where: { ($0["bundle_id"] as? String).map { $0 != finder } ?? false })?["bundle_id"] as? String else { return }
    #expect(textOf(try setup.server.call("get_window_state", ["app": other])).hasPrefix("not_approved"))
  }

  @Test func theListHoldsForAProcessThatTalksToTheSocketDirectly() throws {
    let setup = try Setup()
    let socket = try RawSocket(setup.home.socketPath)
    socket.send(line(["id": 1, "method": "press", "params": ["app": finder, "element": 1, "pid": 1]]))
    let reply = try until { socket.received.contains("\n") ? parseLine(socket.received.components(separatedBy: "\n")[0]) : nil }
    #expect((reply["error"] as? Object)?["code"] as? String == "not_approved")
  }

  @Test func refusesTheLoginWindow() throws {
    let setup = try Setup()
    #expect(try setup.server.call("get_window_state", ["app": "com.apple.loginwindow"])["isError"] as? Bool == true)
  }

  @Test(arguments: ["../../tmp/evil", "/Applications/Calculator", "x/y"])
  func launchAppRefusesAPath(query: String) throws {
    let setup = try Setup()
    #expect(textOf(try setup.server.call("launch_app", ["app": query])).hasPrefix("invalid_request"))
  }

  @Test func launchAppReportsAnAppThatIsNotInstalled() throws {
    let setup = try Setup()
    #expect(textOf(try setup.server.call("launch_app", ["app": "No Such App 123"])).hasPrefix("app_not_found"))
  }

  // Whichever of these apps is installed and not running; the user may have any of them open.
  @Test func anAppThatIsNotOnTheListIsNotLaunched() throws {
    let setup = try Setup()
    let candidates = ["Chess", "Grapher", "Stickies", "Font Book", "Calculator"]
    let stopped = try candidates.compactMap { name -> Object? in
      let app = parseLine(textOf(try setup.server.call("list_apps", ["app": name])))?["app"] as? Object
      return app?["running"] as? Bool == false ? app : nil
    }.first
    guard let stopped, let bundleId = stopped["bundle_id"] as? String, let name = stopped["name"] as? String else { return }
    #expect(textOf(try setup.server.call("launch_app", ["app": name])).hasPrefix("not_approved"))
    Thread.sleep(forTimeInterval: 0.5)
    #expect(try !apps(setup.server).contains { $0["bundle_id"] as? String == bundleId })
  }

  @Test func survivesAClientThatDisconnectsDuringAReply() throws {
    let setup = try Setup()
    for _ in 0..<20 {
      // The listen queue is short, so a connection may have to try again.
      let socket = try until { try? RawSocket(setup.home.socketPath) }
      socket.send(line(["id": 1, "method": "list_apps"]))
    }
    Thread.sleep(forTimeInterval: 0.2)
    #expect(setup.helper.process.isRunning)
    let other = try ServerProcess(home: setup.home)
    #expect(try !apps(other).isEmpty)
  }

  @Test func answersBadJSONOnTheSocketAndKeepsServing() throws {
    let setup = try Setup()
    let socket = try RawSocket(setup.home.socketPath)
    socket.send("{broken")
    _ = try until { socket.received.contains("invalid_request") ? true : nil }
    socket.send(line(["id": 2, "method": "nonsense"]))
    _ = try until { socket.received.contains("unknown_method") ? true : nil }
  }

  // The refusal names no request; the connection closes when the line is still incomplete past the limit.
  @Test func refusesARequestOverTheSizeLimitAndKeepsServing() throws {
    let setup = try Setup()
    let socket = try RawSocket(setup.home.socketPath)
    socket.send(line(["id": 1, "method": "list_apps", "params": ["padding": String(repeating: "x", count: maxFrameBytes + 1)]]))
    let refusal = try until { socket.replies.first }
    #expect((refusal["error"] as? Object)?["code"] as? String == "request_too_large")
    #expect(refusal["id"] is NSNull)
    let other = try RawSocket(setup.home.socketPath)
    other.send(line(["id": 2, "method": "list_apps"]))
    _ = try until { other.replies.first { ($0["id"] as? Int) == 2 } }
  }

  @Test func refusesRequestsBeyondTheQueueOfOneConnection() throws {
    let setup = try Setup()
    let socket = try RawSocket(setup.home.socketPath)
    let count = 200
    socket.send((1...count).map { line(["id": $0, "method": "list_apps"]) }.joined(separator: "\n"))
    let replies = try until { socket.replies.count == count ? socket.replies : nil }
    let busy = replies.filter { ($0["error"] as? Object)?["code"] as? String == "busy" }
    #expect(!busy.isEmpty)
    #expect(replies.count - busy.count >= 64)
    #expect(replies.allSatisfy { $0["result"] != nil || ($0["error"] as? Object)?["code"] as? String == "busy" })
  }

  @Test func refusesConnectionsBeyondTheLimitAndServesOnceOneCloses() throws {
    let setup = try Setup()
    // The listen queue is short, so a connection may have to try again; one that answers holds its place.
    var open = try (0..<64).map { _ in try until { try? RawSocket(setup.home.socketPath) } }
    for socket in open { socket.send(line(["id": 1, "method": "status"])) }
    _ = try until { open.allSatisfy { !$0.replies.isEmpty } ? true : nil }
    let refused = try RawSocket(setup.home.socketPath)
    _ = try until { refused.ended ? true : nil }
    #expect(open.allSatisfy { !$0.ended })
    open.removeLast()
    let later = try until { () -> RawSocket? in
      // A connection the full listen queue refuses is tried again.
      guard let socket = try? RawSocket(setup.home.socketPath) else { return nil }
      socket.send(line(["id": 2, "method": "list_apps"]))
      // A connection that gets no answer yet is tried again.
      return (try? until(timeout: 1) { socket.replies.isEmpty ? nil : true }) != nil ? socket : nil
    }
    #expect(later.replies.first?["result"] != nil)
    withExtendedLifetime(open) {}
  }

  @Test func cancelsAQueuedRequestAndRunsALaterOneWithTheSameId() throws {
    let setup = try Setup()
    let socket = try RawSocket(setup.home.socketPath)
    let queued = (1...30).map { line(["id": $0, "method": "list_apps"]) }
    socket.send((queued + [line(["method": "cancel", "params": ["id": 30]])]).joined(separator: "\n"))
    let cancelled = try until { socket.replies.first { ($0["id"] as? Int) == 30 } }
    #expect((cancelled["error"] as? Object)?["code"] as? String == "cancelled")
    #expect(socket.replies.filter { ($0["id"] as? Int) ?? 0 < 30 }.allSatisfy { $0["result"] != nil })
    socket.send(line(["id": 30, "method": "list_apps"]))
    let again = try until { socket.replies.filter { ($0["id"] as? Int) == 30 }.dropFirst().first }
    #expect(again["result"] != nil)
  }

  @Test func skipsARequestWhoseDeadlineHasPassed() throws {
    let setup = try Setup()
    let socket = try RawSocket(setup.home.socketPath)
    socket.send(line(["id": 1, "method": "list_apps", "deadline": 1]))
    _ = try until { socket.received.contains("expired") ? true : nil }
  }

  @Test func keepsItsFilesPrivateToTheUser() throws {
    let setup = try Setup(allowed: [finder])
    for name in ["helper.sock", "decisions.jsonl", "approvals.json"] {
      let mode = (try FileManager.default.attributesOfItem(atPath: setup.home.path + "/" + name)[.posixPermissions] as? Int) ?? 0o777
      #expect(mode & 0o077 == 0, "\(name)")
    }
  }

  @Test func logsTheFirstUseOfAnAppWithoutContent() throws {
    let setup = try Setup(allowed: [finder])
    _ = try setup.server.call("type_text", ["app": finder, "text": "secret text"])
    _ = try setup.server.call("type_text", ["app": finder, "text": "secret text"])
    let log = try String(contentsOfFile: setup.home.path + "/decisions.jsonl", encoding: .utf8)
    let entries = log.split(separator: "\n").compactMap { parseLine(String($0)) }
    #expect(entries.map { $0["decision"] as? String } == ["added", "used"])
    #expect(entries.last?["app"] as? String == finder)
    #expect(entries.last?["client"] as? String == "claude-code")
    #expect(!log.contains("secret"))
  }

  @Test func listsAndRemovesAppsOnTheListThroughTheHelper() throws {
    let home = TemporaryHome()
    let helper = try RealHelper(home: home)
    try #"{"approvals":[{"bundle_id":"com.one","signer":"team:A"},{"bundle_id":"com.two","signer":"team:B"}]}"#
      .write(toFile: home.path + "/approvals.json", atomically: true, encoding: .utf8)
    #expect(try cli(home, "approvals").output.contains("com.one (team:A)\ncom.two (team:B)"))
    #expect(try cli(home, "approvals", "revoke", "com.one").status == 0)
    #expect(try !cli(home, "approvals", "list").output.contains("com.one"))
    #expect(try cli(home, "approvals", "revoke", "com.other").status == 1)
    let mode = (try FileManager.default.attributesOfItem(atPath: home.path + "/approvals.json")[.posixPermissions] as? Int) ?? 0o777
    #expect(mode & 0o077 == 0)
    withExtendedLifetime(helper) {}
  }

  @Test func anEntryNamingAnotherSignerAllowsNothing() throws {
    let home = TemporaryHome()
    let helper = try RealHelper(home: home)
    try #"{"approvals":[{"bundle_id":"com.apple.finder","signer":"team:SOMEONE-ELSE"}]}"#.write(toFile: home.path + "/approvals.json", atomically: true, encoding: .utf8)
    let server = try ServerProcess(home: home)
    #expect(textOf(try server.call("get_window_state", ["app": finder])).hasPrefix("not_approved"))
    withExtendedLifetime(helper) {}
  }

  @Test func aDamagedListFileAllowsNothing() throws {
    let home = TemporaryHome()
    let helper = try RealHelper(home: home)
    try "{not json".write(toFile: home.path + "/approvals.json", atomically: true, encoding: .utf8)
    let server = try ServerProcess(home: home)
    #expect(textOf(try server.call("get_window_state", ["app": finder])).hasPrefix("not_approved"))
    withExtendedLifetime(helper) {}
  }

  // Only the refusal: the confirmed path also moves the installed app to the Trash and resets the real macOS
  // permissions and MCP registrations, which no test may touch.
  @Test func uninstallWithResetChangesNothingWithoutYes() throws {
    let home = TemporaryHome()
    let kept = home.path + "/.config/backstage"
    try FileManager.default.createDirectory(atPath: kept, withIntermediateDirectories: true)
    for answer in ["no\n", "\n", ""] {
      let result = try cli(home, input: answer, "uninstall", "--reset")
      #expect(result.status == 1)
      #expect(result.output.contains("Nothing was removed."))
      #expect(FileManager.default.fileExists(atPath: kept))
    }
  }

  // The description sent to agents names every app the helper has ready operations for.
  @Test func theToolListNamesEveryAppWithOperations() throws {
    let setup = try Setup()
    let listed = parseLine(textOf(try setup.server.call("list_operations")))?["apps"] as? [Object] ?? []
    let withOperations = listed.filter { !($0["operations"] as? [String] ?? []).isEmpty }.compactMap { $0["app"] as? String }
    #expect(!withOperations.isEmpty)
    let toolList = try #require(try setup.server.request("tools/list")["result"] as? Object)
    let tools = try #require(toolList["tools"] as? [Object])
    let description = tools.first { $0["name"] as? String == "list_operations" }?["description"] as? String ?? ""
    for app in withOperations { #expect(description.contains(app), "\(app)") }
  }

  @Test func explainsItsCommands() throws {
    let result = try cli(TemporaryHome(), "nonsense")
    #expect(result.status == 2)
    #expect(result.output.contains("backstage doctor"))
  }

  @Test func theDockIsNotReachableAsAnApp() throws {
    let setup = try Setup()
    #expect(textOf(try setup.server.call("get_window_state", ["app": "Dock"])).hasPrefix("app_not_found"))
  }
}
