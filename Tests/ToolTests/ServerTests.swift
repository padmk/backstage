// The MCP server against a fake helper: protocol, argument checks and error reporting.

import Foundation
import HelperLink
import Testing

private struct Setup {
  let home = TemporaryHome()
  let helper: FakeHelper
  let server: ServerProcess

  init(_ respond: @escaping @Sendable (Object) -> Object? = { _ in ["result": [:] as Object] }) throws {
    helper = try FakeHelper(home: home, respond: respond)
    server = try ServerProcess(home: home)
  }
}

private func statelessMeta(_ protocolVersion: String = "2026-07-28") -> Object {
  [
    "io.modelcontextprotocol/protocolVersion": protocolVersion,
    "io.modelcontextprotocol/clientCapabilities": [:] as Object,
    "io.modelcontextprotocol/clientInfo": ["name": "modern-client", "version": "1"],
  ]
}

@Suite struct ServerTests {
  @Test func answersInitializeWithTheClientsProtocolVersionAndItsOwnName() throws {
    let setup = try Setup()
    let result = try #require(try setup.server.initialize("claude-code", "2025-03-26")["result"] as? Object)
    #expect(result["protocolVersion"] as? String == "2025-03-26")
    #expect((result["serverInfo"] as? Object)?["name"] as? String == "backstage")
    #expect((result["capabilities"] as? Object)?["tools"] != nil)
  }

  @Test func fallsBackToAProtocolItKnows() throws {
    let setup = try Setup()
    let result = try #require(try setup.server.initialize("x", "1999-01-01")["result"] as? Object)
    #expect(result["protocolVersion"] as? String == "2025-11-25")
  }

  @Test func answersDiscoverWithoutInitializeAndRefusesARevisionItDoesNotServeThatWay() throws {
    let setup = try Setup()
    let result = try #require(try setup.server.request("server/discover", ["_meta": statelessMeta()])["result"] as? Object)
    #expect(result["resultType"] as? String == "complete")
    #expect((result["supportedVersions"] as? [String])?.contains("2026-07-28") == true)
    #expect((result["capabilities"] as? Object)?["tools"] != nil)
    #expect(((result["_meta"] as? Object)?["io.modelcontextprotocol/serverInfo"] as? Object)?["name"] as? String == "backstage")
    let error = try #require(try setup.server.request("server/discover", ["_meta": statelessMeta("1999-01-01")])["error"] as? Object)
    #expect(error["code"] as? Int == -32022)
    #expect((error["data"] as? Object)?["requested"] as? String == "1999-01-01")
  }

  @Test func runsAToolForARequestThatCarriesItsRevisionNamingTheClientFromIt() throws {
    let setup = try Setup()
    let result = try #require(try setup.server.request("tools/call", ["name": "list_apps", "arguments": [:] as Object, "_meta": statelessMeta()])["result"] as? Object)
    #expect(result["resultType"] as? String == "complete")
    #expect((setup.helper.first("hello")?["params"] as? Object)?["client_name"] as? String == "modern-client")
  }

  @Test func listsToolsWithSchemasThatRejectUnknownArguments() throws {
    let setup = try Setup()
    let listed = try #require(try setup.server.request("tools/list")["result"] as? Object)
    let tools = try #require(listed["tools"] as? [Object])
    #expect(tools.map { $0["name"] as? String } == ["list_apps", "launch_app", "list_operations", "run_operation", "get_window_state", "read_text", "screenshot", "press", "set_value", "type_text", "select_text", "press_key", "scroll", "drag", "click_at", "list_windows", "set_window", "set_app_state", "close", "list_menu_commands", "run_menu_command", "wait_for", "record_audio", "run_actions"])
    for tool in tools { #expect((tool["inputSchema"] as? Object)?["additionalProperties"] as? Bool == false) }
  }

  @Test func answersPingAndRefusesUnknownMethods() throws {
    let setup = try Setup()
    #expect((try setup.server.request("ping")["result"] as? Object)?.isEmpty == true)
    #expect((try setup.server.request("nonsense")["error"] as? Object)?["code"] as? Int == -32601)
  }

  @Test(arguments: [("null", -32600), ("[1]", -32600), ("{broken", -32700), (#"{"id":1,"method":"x","params":5}"#, -32600)])
  func answersABadLineAndKeepsWorking(line: String, code: Int) throws {
    let setup = try Setup()
    setup.server.write(line)
    let error = try until { setup.server.received.first { $0["error"] != nil } }
    #expect((error["error"] as? Object)?["code"] as? Int == code)
    #expect(try setup.server.request("ping")["result"] != nil)
  }

  @Test func keepsLineSeparatorsInsideAMessage() throws {
    let setup = try Setup()
    _ = try setup.server.call("type_text", ["app": "Notes", "text": "a\u{2028}b"])
    #expect((setup.helper.first("type_text")?["params"] as? Object)?["text"] as? String == "a\u{2028}b")
  }

  @Test(arguments: [
    ("press", #"{"app":"Notes"}"#, "element is required"),
    ("press", #"{"app":"Notes","element":"5"}"#, "element must be a whole number"),
    ("press", #"{"app":"Notes","element":0}"#, "at least 1"),
    ("press", #"{"app":5,"element":1}"#, "app must be a string"),
    ("press", #"{"app":"Notes","element":1,"pid":1}"#, "unknown argument pid"),
    ("click_at", #"{"app":"Notes","x":1,"y":1,"count":2147483647}"#, "at most 3"),
    ("click_at", #"{"app":"Notes","x":"1","y":1}"#, "x must be a number"),
    ("click_at", #"{"app":"Notes","x":-1,"y":1}"#, "at least 0"),
    ("scroll", #"{"app":"Notes","element":1,"direction":"sideways"}"#, "one of"),
    ("get_window_state", #"{"app":"Notes","max_elements":1000000}"#, "at most 5000"),
    ("launch_app", "{}", "app is required"),
    ("press", #"{"app":"Notes","element":true}"#, "element must be a whole number"),
    ("press", #"{"app":"Notes","element":1.5}"#, "element must be a whole number"),
  ])
  func refusesBadArgumentsBeforeTheHelper(name: String, arguments: String, expected: String) throws {
    let setup = try Setup()
    let result = try setup.server.call(name, parseLine(arguments)!)
    #expect(result["isError"] as? Bool == true)
    #expect(textOf(result).contains(expected))
    #expect(setup.helper.first(name) == nil)
  }

  @Test func refusesArgumentsThatAreNotAnObject() throws {
    let setup = try Setup()
    let result = try #require(try setup.server.request("tools/call", ["name": "press", "arguments": [1]])["result"] as? Object)
    #expect(result["isError"] as? Bool == true)
  }

  @Test func refusesAnUnknownToolIncludingNamesOnObject() throws {
    let setup = try Setup()
    for name in ["nonsense", "constructor", "__proto__"] {
      #expect((try setup.server.request("tools/call", ["name": name, "arguments": [:] as Object])["error"] as? Object)?["code"] as? Int == -32602)
    }
  }

  @Test func passesTheClientsNameAndAStableSessionIdToTheHelper() throws {
    let setup = try Setup()
    _ = try setup.server.initialize("claude-code")
    _ = try setup.server.call("list_apps")
    let hello = setup.helper.first("hello")?["params"] as? Object
    #expect(hello?["client_name"] as? String == "claude-code")
    #expect((hello?["session_id"] as? String)?.isEmpty == false)
  }

  @Test func everyRequestCarriesADeadline() throws {
    let setup = try Setup()
    _ = try setup.server.call("list_apps")
    let deadline = setup.helper.first("list_apps")?["deadline"] as? Double ?? 0
    #expect(deadline > Date().timeIntervalSince1970 * 1000)
  }

  @Test func returnsAScreenshotAsAnImage() throws {
    let setup = try Setup { _ in ["result": ["png_base64": "QUJD", "width": 2, "height": 3]] }
    let result = try setup.server.call("screenshot", ["app": "Notes"])
    let content = try #require(result["content"] as? [Object])
    #expect(content[0]["type"] as? String == "image")
    #expect(content[0]["data"] as? String == "QUJD")
    #expect(content[0]["mimeType"] as? String == "image/png")
    #expect((content[1]["text"] as? String)?.contains(#""width":2"#) == true)
  }

  @Test func returnsTheTreeAsPlainText() throws {
    let setup = try Setup { _ in ["result": ["tree": "app=\"Notes\"\n1 Button"]] }
    #expect(textOf(try setup.server.call("get_window_state", ["app": "Notes"])) == "app=\"Notes\"\n1 Button")
  }

  @Test func namesTheErrorFromTheHelper() throws {
    let setup = try Setup { _ in ["error": ["code": "declined", "message": "The user declined Notes."]] }
    let result = try setup.server.call("press", ["app": "Notes", "element": 1])
    #expect(result["isError"] as? Bool == true)
    #expect(textOf(result) == "declined: The user declined Notes.")
  }

  @Test func passesTheHelpersAdviceForAMissingPermissionOnUnchanged() throws {
    let setup = try Setup { _ in ["error": ["code": "permission_missing", "message": "Ask the user to allow it on the Setup tab."]] }
    #expect(textOf(try setup.server.call("get_window_state", ["app": "Notes"])) == "permission_missing: Ask the user to allow it on the Setup tab.")
  }

  @Test func forwardsACancellationToTheHelper() throws {
    let setup = try Setup { _ in nil }
    setup.server.write(line(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "press", "arguments": ["app": "Notes", "element": 1]]]))
    _ = try until { setup.helper.first("press") }
    setup.server.write(line(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 1]]))
    let cancel = try until { setup.helper.first("cancel") }
    #expect((cancel["params"] as? Object)?["id"] as? Int == setup.helper.first("press")?["id"] as? Int)
    setup.helper.disconnectAll()
    let reply = try until { setup.server.received.first { ($0["id"] as? Int) == 1 } }
    #expect((reply["result"] as? Object)?["isError"] as? Bool == true)
  }

  @Test func reportsAHelperThatGoesAwayAndConnectsAgainAfterwards() throws {
    let setup = try Setup { $0["method"] as? String == "press" ? nil : ["result": ["ok": true]] }
    setup.server.write(line(["jsonrpc": "2.0", "id": 99, "method": "tools/call", "params": ["name": "press", "arguments": ["app": "Notes", "element": 1]]]))
    _ = try until { setup.helper.first("press") }
    setup.helper.disconnectAll()
    let reply = try #require(try until { setup.server.received.first { ($0["id"] as? Int) == 99 } }["result"] as? Object)
    #expect(reply["isError"] as? Bool == true)
    #expect(textOf(reply).contains("may or may not have run"))
    Thread.sleep(forTimeInterval: 0.05)
    #expect(textOf(try setup.server.call("list_apps")).contains("ok"))
  }

  @Test func refusesARequestTooLargeForTheHelperWithoutHurtingAnotherCall() throws {
    let setup = try Setup { request in
      if request["method"] as? String == "press" { Thread.sleep(forTimeInterval: 0.5) }
      return ["result": ["ok": true]]
    }
    setup.server.write(line(["jsonrpc": "2.0", "id": 100, "method": "tools/call", "params": ["name": "press", "arguments": ["app": "Notes", "element": 1]]]))
    _ = try until { setup.helper.first("press") }
    let large = String(repeating: "x", count: 5 << 20)
    let refused = try setup.server.call("run_operation", ["app": "Notes", "operation": "create", "arguments": ["body": large]])
    #expect(textOf(refused).hasPrefix("request_too_large"))
    let pressed = try #require(try until { setup.server.received.first { ($0["id"] as? Int) == 100 } }["result"] as? Object)
    #expect(textOf(pressed).contains("ok"))
    #expect(setup.helper.first("run_operation") == nil)
  }

  @Test func endsACallWhenTheHelperAnswersWithAnErrorThatNamesNoRequest() throws {
    let setup = try Setup { _ in ["id": NSNull(), "error": ["code": "request_too_large", "message": "Too large."]] }
    let result = try setup.server.call("press", ["app": "Notes", "element": 1])
    #expect(result["isError"] as? Bool == true)
    #expect(textOf(result).hasPrefix("helper_stopped"))
  }

  // A line that is no JSON names no request either, so it ends the call rather than leave it waiting for its deadline.
  @Test func endsACallWhenTheHelperAnswersWithALineThatIsNoJSON() throws {
    let home = TemporaryHome()
    let helper = try FakeHelper(home: home) { $0["method"] as? String == "press" ? ["raw": "{broken"] : ["result": [:] as Object] }
    let server = try ServerProcess(home: home, environment: ["HELPER_TEST_TIMEOUT": "5"])
    let result = try server.call("press", ["app": "Notes", "element": 1])
    #expect(textOf(result).hasPrefix("helper_stopped"), "\(textOf(result))")
    withExtendedLifetime(helper) {}
  }

  @Test func reportsAHelperThatDoesNotAnswerInTimeAndConnectsAgainAfterwards() throws {
    let home = TemporaryHome()
    let helper = try FakeHelper(home: home) { $0["method"] as? String == "press" ? nil : ["result": ["ok": true]] }
    let server = try ServerProcess(home: home, environment: ["HELPER_TEST_TIMEOUT": "1"])
    let result = try server.call("press", ["app": "Notes", "element": 1])
    #expect(textOf(result).hasPrefix("timeout:"))
    #expect(textOf(result).contains("may or may not have run"))
    #expect(textOf(try until { () -> Object? in
      // A call while the helper restarts fails and is tried again.
      let next = try? server.call("list_apps")
      return next?["isError"] as? Bool == true ? nil : next
    }).contains("ok"))
    #expect(helper.all("hello").count == 2)
  }

  // A helper that refuses the session, as one restarting does, keeps the connection open; the command ends it, so no
  // retry leaves a connection and a reader behind.
  @Test func endsTheConnectionWhenTheHelperRefusesItsHello() throws {
    let home = TemporaryHome()
    let helper = try FakeHelper(home: home, helloError: ["code": "restarting", "message": "Restarting."])
    let server = try ServerProcess(home: home)
    #expect(textOf(try server.call("list_apps")).hasPrefix("restarting"))
    try until { helper.connectionsEnded == 1 ? true : nil }
  }

  // A helper that restarted has forgotten the session, so numbers from before must not name its new elements.
  @Test func numbersElementsFromANewRangeOnEveryNewConnection() throws {
    let setup = try Setup { _ in ["result": ["ok": true]] }
    _ = try setup.server.call("list_apps")
    setup.helper.disconnectAll()
    _ = try until { () -> Object? in
      // A call while the helper restarts fails and is tried again.
      let next = try? setup.server.call("list_apps")
      return next?["isError"] as? Bool == true ? nil : next
    }
    let hellos = setup.helper.all("hello").map { $0["params"] as? Object ?? [:] }
    #expect(hellos.count == 2)
    #expect(hellos[0]["session_id"] as? String == hellos[1]["session_id"] as? String)
    #expect(hellos[0]["first_element_number"] == nil)
    #expect((hellos[1]["first_element_number"] as? Int ?? 0) > 100_000)
    // Each range ends where the next connection's begins, and the helper stops numbering there.
    #expect(hellos[0]["element_number_limit"] as? Int == hellos[1]["first_element_number"] as? Int)
    #expect(hellos[1]["element_number_limit"] as? Int == (hellos[1]["first_element_number"] as? Int ?? 0) + 1_000_000)
  }

  // MARK: Builds

  private func managing(_ installed: String) -> [String: String] { ["HELPER_NO_START": "", "HELPER_TEST_INSTALLED_APP": installed] }

  @Test func replacesAHelperOfAnotherBuildWhenTheInstalledAppIsItsOwn() throws {
    let home = TemporaryHome()
    let installed = try FakeBundle(in: home, named: "Installed", build: 0xA1)
    let helper = try FakeHelper(home: home, builds: ["other", installed.build])
    let server = try ServerProcess(home: home, executable: installed.command, environment: managing(installed.path))
    #expect(try server.call("list_apps")["isError"] as? Bool != true)
    #expect(helper.requests.map { $0["method"] as? String ?? "" } == ["hello", "quit", "hello", "list_apps"])
  }

  @Test func anOlderCommandNeverStopsTheHelperOfTheInstalledApp() throws {
    let home = TemporaryHome()
    let installed = try FakeBundle(in: home, named: "Installed", build: 0xA1)
    let older = try FakeBundle(in: home, named: "Older", build: 0xB2)
    let helper = try FakeHelper(home: home, builds: [installed.build])
    let server = try ServerProcess(home: home, executable: older.command, environment: managing(installed.path))
    let result = try server.call("list_apps")
    #expect(result["isError"] as? Bool == true)
    #expect(textOf(result).contains("belongs to another build"))
    #expect(helper.first("quit") == nil)
    #expect(helper.first("list_apps") == nil)
  }

  @Test func asksForSetupWhenNoAppIsInstalled() throws {
    let home = TemporaryHome()
    let command = try FakeBundle(in: home, named: "Command", build: 0xB2)
    let server = try ServerProcess(home: home, executable: command.command, environment: managing(home.path + "/Missing.app"))
    let text = textOf(try server.call("list_apps"))
    #expect(text.contains("is not installed. Run:") && text.hasSuffix("setup"))
  }

  @Test func handsTheSessionWithItsCallInFlightToTheInstalledCommand() throws {
    let home = TemporaryHome()
    let installed = try FakeBundle(in: home, named: "Installed", build: 0xA1, handoffRevision: Product.sessionHandoffRevision)
    let older = try FakeBundle(in: home, named: "Older", build: 0xB2)
    let helper = try FakeHelper(home: home, builds: [installed.build]) { _ in ["result": ["ok": true]] }
    let server = try ServerProcess(home: home, executable: older.command, environment: managing(installed.path))
    _ = try server.initialize("claude-code")
    let pressed = try server.call("press", ["app": "Notes", "element": 1])
    #expect(textOf(pressed).contains("ok"))
    Thread.sleep(forTimeInterval: 0.2)
    #expect(server.process.isRunning)
    #expect(server.received.filter { ($0["id"] as? Int) == 2 }.count == 1)
    #expect(!server.received.contains { $0["method"] as? String == "notifications/tools/list_changed" })
    #expect(helper.all("press").count == 1)
    #expect(helper.first("quit") == nil)
    let hellos = helper.all("hello").map { $0["params"] as? Object ?? [:] }
    #expect(hellos.count == 2)
    #expect(hellos.last?["first_element_number"] as? Int == 100_000_001)
    #expect(hellos.last?["client_name"] as? String == "claude-code")
  }

  // A restart that cannot take the start lock still ends the connection to the helper it meant to replace.
  @Test func endsTheConnectionWhenTheStartLockCannotBeTaken() throws {
    let home = TemporaryHome()
    let installed = try FakeBundle(in: home, named: "Installed", build: 0xA1)
    let helper = try FakeHelper(home: home, builds: ["other"])
    let lock = open(home.path + "/start-lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    defer { close(lock) }
    #expect(flock(lock, LOCK_EX) == 0)
    let server = try ServerProcess(home: home, executable: installed.command, environment: managing(installed.path).merging(["HELPER_TEST_TIMEOUT": "1"]) { $1 })
    let result = try server.call("list_apps")
    #expect(result["isError"] as? Bool == true)
    #expect(textOf(result).contains("still holds"), "\(textOf(result))")
    try until { helper.connectionsEnded == 1 ? true : nil }
    #expect(helper.first("quit") == nil)
  }

  // A bundle of the first handoff revision drops a stop signal pending at its start, so a session never moves to it.
  @Test func aBundleOfTheFirstHandoffRevisionGetsNoSession() throws {
    let home = TemporaryHome()
    let installed = try FakeBundle(in: home, named: "Installed", build: 0xA1, handoffRevision: 1)
    let older = try FakeBundle(in: home, named: "Older", build: 0xB2)
    let helper = try FakeHelper(home: home, builds: [installed.build]) { _ in ["result": ["ok": true]] }
    let server = try ServerProcess(home: home, executable: older.command, environment: managing(installed.path))
    let pressed = try server.call("press", ["app": "Notes", "element": 1])
    #expect(textOf(pressed).contains("belongs to another build"), "\(textOf(pressed))")
    #expect(helper.all("hello").count == 1)
    #expect(helper.first("press") == nil)
  }

  // An older command whose client does not read: the replies fill the pipe, and the call that finds the newer build
  // starts a handoff that waits for that output.
  private func handoffWaitingForOutput(_ home: TemporaryHome) throws -> (helper: FakeHelper, server: ServerProcess) {
    let installed = try FakeBundle(in: home, named: "Installed", build: 0xA1, handoffRevision: Product.sessionHandoffRevision)
    let older = try FakeBundle(in: home, named: "Older", build: 0xB2)
    let helper = try FakeHelper(home: home, builds: [installed.build]) { _ in ["result": ["ok": true]] }
    let server = try ServerProcess(home: home, executable: older.command, environment: managing(installed.path), readsOutput: false)
    for id in 1...200 { server.write(line(["jsonrpc": "2.0", "id": id, "method": "tools/list"])) }
    // Once the replies have filled the pipe, the rest wait to be written.
    try server.waitUntilOutputIsFull()
    server.write(line(["jsonrpc": "2.0", "id": 1000, "method": "tools/call", "params": ["name": "press", "arguments": ["app": "Notes", "element": 1]]]))
    try until { helper.all("hello").count == 1 ? true : nil }
    return (helper, server)
  }

  // The exec would cut a reply in the middle, so the handoff gives up and this command goes on serving the client.
  @Test func aHandoffGivesUpWhileTheClientDoesNotReadAndInputGoesOn() throws {
    let home = TemporaryHome()
    let (helper, server) = try handoffWaitingForOutput(home)
    // Well past the 1 s the handoff waits for the output.
    Thread.sleep(forTimeInterval: 2.5)
    server.startReading()
    let pressed = try #require(try until { server.received.first { ($0["id"] as? Int) == 1000 } }["result"] as? Object)
    #expect(textOf(pressed).contains("belongs to another build"), "\(textOf(pressed))")
    // An id no earlier request used, so only this ping's own answer counts.
    server.write(line(["jsonrpc": "2.0", "id": 2000, "method": "ping"]))
    let pong = try until { server.received.first { ($0["id"] as? Int) == 2000 } }
    #expect((pong["result"] as? Object)?.isEmpty == true)
    #expect(helper.all("hello").count == 1)
    #expect(helper.first("press") == nil)
  }

  @Test func reportsNoHelperInsteadOfHanging() throws {
    let home = TemporaryHome()
    let server = try ServerProcess(home: home)
    let result = try server.call("list_apps")
    #expect(result["isError"] as? Bool == true)
    #expect(textOf(result).contains("No helper listens"))
  }

  @Test func endsWhenTheClientClosesItsSide() throws {
    let setup = try Setup()
    setup.server.closeInput()
    let ended = try setup.server.waitForExit()
    #expect(ended.status == 0 && ended.reason == .exit)
  }

  // Replies to a client that stopped reading fill the pipe and block the output; a signal still ends the process.
  // The command answers a ping first, so the signal arrives once it handles signals, not while it still starts.
  @Test func endsOnASignalWhileTheClientDoesNotRead() throws {
    let home = TemporaryHome()
    let server = try ServerProcess(home: home, readsOutput: false)
    server.write(line(["jsonrpc": "2.0", "id": 0, "method": "ping"]))
    #expect(server.readOneLine()?["id"] as? Int == 0)
    for id in 1...200 { server.write(line(["jsonrpc": "2.0", "id": id, "method": "tools/list"])) }
    try server.waitUntilOutputIsFull()
    kill(server.process.processIdentifier, SIGTERM)
    // A process that hangs is killed, so it does not outlive the test.
    defer { if server.process.isRunning { kill(server.process.processIdentifier, SIGKILL) } }
    let ended = try server.waitForExit(timeout: 5)
    #expect(ended.status == 0 && ended.reason == .exit)
  }

  // A handoff execs the next command with the stop signals blocked, so one that came during the exec is pending there.
  // Started suspended with SIGTERM blocked and then sent it, the command is in that state; it must stop.
  @Test func aStopSignalPendingAtStartStopsTheCommand() throws {
    let home = TemporaryHome()
    let command = try SpawnedCommand(home: home, termBlocked: true, suspended: true)
    kill(command.pid, SIGTERM)
    kill(command.pid, SIGCONT)
    #expect(command.exitedCleanly())
  }

  // The state of a handoff comes in a regular file; a pipe that never ends must not keep a stop waiting.
  @Test func aStopWhileTheHandoffStateIsAPipeEndsTheCommand() throws {
    let home = TemporaryHome()
    var resume: [Int32] = [0, 0]
    #expect(pipe(&resume) == 0)
    defer { close(resume[1]) }
    // Blocked from the start, so the signal waits for the command however long it takes to start.
    let command = try SpawnedCommand(home: home, termBlocked: true, resume: resume[0])
    close(resume[0])
    // The pipe's writer stays open, so only a command that does not read it from the pipe serves.
    command.write(line(["jsonrpc": "2.0", "id": 1, "method": "ping"]))
    #expect(command.readOneLine()?["id"] as? Int == 1)
    kill(command.pid, SIGTERM)
    #expect(command.exitedCleanly())
  }

  // A stop that begins before the server is attached ends the process with nothing handled and nothing said: the
  // stop is held after it began while the main thread reaches the attach, a handoff passed on a press and a new tool
  // list, and another press waits on stdin.
  @Test func aStopBeforeTheServerIsAttachedHandlesAndSaysNothing() throws {
    let home = TemporaryHome()
    let helper = try FakeHelper(home: home)
    let press = line(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "press", "arguments": ["app": "Notes", "element": 1]]])
    let state = home.path + "/state"
    try (line(["tools_digest": "an older list", "generation": 1]) + "\n" + press + "\n").write(toFile: state, atomically: true, encoding: .utf8)
    let resume = open(state, O_RDONLY)
    #expect(resume >= 0)
    let command = try SpawnedCommand(home: home, termBlocked: true, suspended: true, resume: resume, environment: ["HELPER_TEST_STOP_DELAY=1"])
    close(resume)
    command.write(press)
    kill(command.pid, SIGTERM)
    kill(command.pid, SIGCONT)
    try until { FileManager.default.fileExists(atPath: home.path + "/stop-hold") ? true : nil }
    #expect(command.exitedCleanly())
    #expect(command.readOneLine(timeout: 1) == nil)
    #expect(helper.requests.isEmpty)
  }

  // Once a stop has begun, the command reads no more input: a ping sent while the stop is held stays unread and
  // gets no answer.
  @Test func aStopWhileServingReadsNoMoreInput() throws {
    let home = TemporaryHome()
    let command = try SpawnedCommand(home: home, termBlocked: true, environment: ["HELPER_TEST_STOP_DELAY=1"])
    command.write(line(["jsonrpc": "2.0", "id": 1, "method": "ping"]))
    #expect(command.readOneLine()?["id"] as? Int == 1)
    kill(command.pid, SIGTERM)
    try until { FileManager.default.fileExists(atPath: home.path + "/stop-hold") ? true : nil }
    let late = line(["jsonrpc": "2.0", "id": 2, "method": "ping"])
    command.write(late)
    #expect(command.exitedCleanly())
    #expect(command.unreadInput == late.utf8.count + 1)
    #expect(command.readOneLine(timeout: 1) == nil)
  }

  // A stop signal while a handoff holds the stop's lock, right before its exec, reaches the installed command.
  @Test func aStopSignalDuringTheExecOfAHandoffStopsTheNextCommand() throws {
    let home = TemporaryHome()
    let installed = try FakeBundle(in: home, named: "Installed", build: 0xA1, handoffRevision: Product.sessionHandoffRevision)
    let older = try FakeBundle(in: home, named: "Older", build: 0xB2)
    let helper = try FakeHelper(home: home, builds: [installed.build]) { _ in ["result": ["ok": true]] }
    let environment = managing(installed.path).merging(["HELPER_TEST_EXEC_DELAY": "1", "HELPER_TEST_STOP_DELAY": "0.1"]) { $1 }
    let server = try ServerProcess(home: home, executable: older.command, environment: environment)
    _ = try server.initialize("claude-code")
    server.write(line(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "press", "arguments": ["app": "Notes", "element": 1]]]))
    try until { FileManager.default.fileExists(atPath: home.path + "/exec-hold") ? true : nil }
    kill(server.process.processIdentifier, SIGTERM)
    // A command that lives on after the handoff is killed, so it does not outlive the test.
    defer { if server.process.isRunning { kill(server.process.processIdentifier, SIGKILL) } }
    let ended = try server.waitForExit(timeout: 5)
    // The stop ran in the installed command, which the exec started with the session's state.
    let stopped = try String(contentsOfFile: home.path + "/stop-hold", encoding: .utf8)
    #expect(stopped.hasPrefix(installed.command) && stopped.contains("--resume-fd"), "\(stopped)")
    #expect(ended.status == 0 && ended.reason == .exit)
    #expect(helper.first("press") == nil)
  }

  // The installed bundle may change after the handoff first looked at it: checked again holding the setup lock, a bundle
  // of the first handoff revision gets no session.
  @Test func aHandoffChecksTheInstalledBundleAgainHoldingTheSetupLock() throws {
    let home = TemporaryHome()
    let installed = try FakeBundle(in: home, named: "Installed", build: 0xA1, handoffRevision: Product.sessionHandoffRevision)
    let older = try FakeBundle(in: home, named: "Older", build: 0xB2)
    let helper = try FakeHelper(home: home, builds: [installed.build]) { _ in ["result": ["ok": true]] }
    // Setup holds its lock, as while it replaces the installed app.
    let lock = open(home.path + "/setup-lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    #expect(lock >= 0 && flock(lock, LOCK_EX) == 0)
    let server = try ServerProcess(home: home, executable: older.command, environment: managing(installed.path))
    _ = try server.initialize("claude-code")
    server.write(line(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "press", "arguments": ["app": "Notes", "element": 1]]]))
    try until { helper.all("hello").count == 1 ? true : nil }
    // The handoff's first look at the bundle follows the hello at once; it then waits for the lock.
    Thread.sleep(forTimeInterval: 0.5)
    try ([Product.sessionHandoffKey: 1] as NSDictionary).write(to: URL(fileURLWithPath: installed.path + "/Contents/Info.plist"))
    close(lock)
    let pressed = try #require(try until { server.received.first { ($0["id"] as? Int) == 2 } }["result"] as? Object)
    #expect(textOf(pressed).contains("belongs to another build"), "\(textOf(pressed))")
    #expect(helper.all("hello").count == 1)
    #expect(helper.first("press") == nil)
  }

  // A handoff holds the lock setup takes to replace the installed app from its last check of that bundle through its
  // exec, so no other bundle comes in between, and the lock does not cross into the installed command.
  @Test func aHandoffHoldsTheSetupLockThroughItsExecAndNotAfter() throws {
    let home = TemporaryHome()
    let installed = try FakeBundle(in: home, named: "Installed", build: 0xA1, handoffRevision: Product.sessionHandoffRevision)
    let older = try FakeBundle(in: home, named: "Older", build: 0xB2)
    let helper = try FakeHelper(home: home, builds: [installed.build]) { _ in ["result": ["ok": true]] }
    let environment = managing(installed.path).merging(["HELPER_TEST_EXEC_DELAY": "0.5"]) { $1 }
    let server = try ServerProcess(home: home, executable: older.command, environment: environment)
    _ = try server.initialize("claude-code")
    server.write(line(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "press", "arguments": ["app": "Notes", "element": 1]]]))
    try until { FileManager.default.fileExists(atPath: home.path + "/exec-hold") ? true : nil }
    let lock = open(home.path + "/setup-lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    #expect(lock >= 0)
    defer { close(lock) }
    #expect(flock(lock, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK)
    // The installed command serves the call, so the exec has happened; the lock is free then.
    let pressed = try #require(try until { server.received.first { ($0["id"] as? Int) == 2 } }["result"] as? Object)
    #expect(textOf(pressed).contains("ok"))
    #expect(helper.all("hello").count == 2)
    #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
  }

  @Test(arguments: [SIGTERM, SIGINT, SIGHUP])
  func endsOnASignal(signal: Int32) throws {
    let setup = try Setup()
    _ = try setup.server.request("ping")
    kill(setup.server.process.processIdentifier, signal)
    let ended = try setup.server.waitForExit()
    #expect(ended.status == 0 && ended.reason == .exit)
  }
}

// `backstage mcp` started with posix_spawn, for what Process cannot set up: a signal mask, a start suspended, and the
// descriptor of a handoff's state. Its stdin and stdout are pipes that stay open until this is gone.
private final class SpawnedCommand {
  let pid: pid_t
  private let input: Int32
  private let output: Int32
  // A copy of the read end of its stdin, so the test can see what the command has not read.
  private let inputReader: Int32

  init(home: TemporaryHome, termBlocked: Bool = false, suspended: Bool = false, resume: Int32? = nil, environment extra: [String] = []) throws {
    var pipeEnds: [Int32] = [0, 0]
    var outputEnds: [Int32] = [0, 0]
    guard pipe(&pipeEnds) == 0, pipe(&outputEnds) == 0 else { throw TestFailure("pipe failed") }
    input = pipeEnds[1]
    output = outputEnds[0]
    inputReader = fcntl(pipeEnds[0], F_DUPFD_CLOEXEC, 0)
    defer {
      close(pipeEnds[0])
      close(outputEnds[1])
    }
    var attributes: posix_spawnattr_t?
    var actions: posix_spawn_file_actions_t?
    posix_spawnattr_init(&attributes)
    posix_spawn_file_actions_init(&actions)
    defer {
      posix_spawnattr_destroy(&attributes)
      posix_spawn_file_actions_destroy(&actions)
    }
    var blocked = sigset_t()
    sigemptyset(&blocked)
    if termBlocked { sigaddset(&blocked, SIGTERM) }
    var defaults = sigset_t()
    sigemptyset(&defaults)
    sigaddset(&defaults, SIGTERM)
    let suspendedFlag = suspended ? POSIX_SPAWN_START_SUSPENDED : 0
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT | suspendedFlag))
    posix_spawnattr_setsigmask(&attributes, &blocked)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawn_file_actions_adddup2(&actions, pipeEnds[0], STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&actions, outputEnds[1], STDOUT_FILENO)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    var arguments = [commandBinary, "mcp"]
    if let resume {
      posix_spawn_file_actions_adddup2(&actions, resume, 3)
      arguments += ["--resume-fd", "3"]
    }
    let environment = ["HOME=\(home.path)", "HELPER_TEST_HOME=\(home.path)", "HELPER_NO_START=1"] + extra
    let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
    defer { (argv + envp).forEach { free($0) } }
    var spawned: pid_t = 0
    guard posix_spawn(&spawned, commandBinary, &actions, &attributes, argv, envp) == 0 else { throw TestFailure("posix_spawn failed") }
    pid = spawned
  }

  // Whether it exited with status 0 within 5 s; one that did not is killed, so it does not outlive the test.
  func exitedCleanly() -> Bool {
    var status: Int32 = 0
    // A timeout means the command lives on, which the answer reports.
    let ended = try? until(timeout: 5) { waitpid(pid, &status, WNOHANG) == pid ? true : nil }
    guard ended == true else {
      kill(pid, SIGKILL)
      waitpid(pid, &status, 0)
      return false
    }
    return status & 0x7f == 0 && (status >> 8) & 0xff == 0
  }

  func write(_ text: String) {
    let bytes = Array((text + "\n").utf8)
    _ = bytes.withUnsafeBytes { Darwin.write(input, $0.baseAddress, $0.count) }
  }

  func readOneLine(timeout: TimeInterval = 10) -> Object? { readLine(output, timeout: timeout) }

  // How many bytes written to its stdin nobody has read.
  var unreadInput: Int {
    var count: Int32 = 0
    _ = ioctl(inputReader, bytesWaitingRequest, &count)
    return Int(count)
  }

  deinit {
    close(input)
    close(output)
    close(inputReader)
  }
}
