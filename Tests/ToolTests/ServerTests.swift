// The MCP server against a fake helper: protocol, argument checks and error reporting.

import Foundation
import HelperLink
import Testing

private struct Setup {
  let home = TemporaryHome()
  let helper: FakeHelper
  let server: ServerProcess

  init(_ respond: @escaping (Object) -> Object? = { _ in ["result": [:] as Object] }) throws {
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
    let result = try setup.server.initialize("claude-code", "2025-03-26")["result"] as! Object
    #expect(result["protocolVersion"] as? String == "2025-03-26")
    #expect((result["serverInfo"] as? Object)?["name"] as? String == "backstage")
    #expect((result["capabilities"] as? Object)?["tools"] != nil)
  }

  @Test func fallsBackToAProtocolItKnows() throws {
    let setup = try Setup()
    let result = try setup.server.initialize("x", "1999-01-01")["result"] as! Object
    #expect(result["protocolVersion"] as? String == "2025-11-25")
  }

  @Test func answersDiscoverWithoutInitializeAndRefusesARevisionItDoesNotServeThatWay() throws {
    let setup = try Setup()
    let result = try setup.server.request("server/discover", ["_meta": statelessMeta()])["result"] as! Object
    #expect(result["resultType"] as? String == "complete")
    #expect((result["supportedVersions"] as? [String])?.contains("2026-07-28") == true)
    #expect((result["capabilities"] as? Object)?["tools"] != nil)
    #expect(((result["_meta"] as? Object)?["io.modelcontextprotocol/serverInfo"] as? Object)?["name"] as? String == "backstage")
    let error = try setup.server.request("server/discover", ["_meta": statelessMeta("1999-01-01")])["error"] as! Object
    #expect(error["code"] as? Int == -32022)
    #expect((error["data"] as? Object)?["requested"] as? String == "1999-01-01")
  }

  @Test func runsAToolForARequestThatCarriesItsRevisionNamingTheClientFromIt() throws {
    let setup = try Setup()
    let result = try setup.server.request("tools/call", ["name": "list_apps", "arguments": [:] as Object, "_meta": statelessMeta()])["result"] as! Object
    #expect(result["resultType"] as? String == "complete")
    #expect((setup.helper.first("hello")?["params"] as? Object)?["client_name"] as? String == "modern-client")
  }

  @Test func listsToolsWithSchemasThatRejectUnknownArguments() throws {
    let setup = try Setup()
    let tools = (try setup.server.request("tools/list")["result"] as! Object)["tools"] as! [Object]
    #expect(tools.map { $0["name"] as! String } == ["list_apps", "launch_app", "list_operations", "run_operation", "get_window_state", "read_text", "screenshot", "press", "set_value", "type_text", "select_text", "press_key", "scroll", "drag", "click_at", "list_windows", "set_window", "set_app_state", "close", "list_menu_commands", "run_menu_command", "wait_for", "record_audio", "run_actions"])
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
    let result = try setup.server.request("tools/call", ["name": "press", "arguments": [1]])["result"] as! Object
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
    let content = result["content"] as! [Object]
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
    let reply = try until { setup.server.received.first { ($0["id"] as? Int) == 99 } }["result"] as! Object
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
    let pressed = try until { setup.server.received.first { ($0["id"] as? Int) == 100 } }["result"] as! Object
    #expect(textOf(pressed).contains("ok"))
    #expect(setup.helper.first("run_operation") == nil)
  }

  @Test func endsACallWhenTheHelperAnswersWithAnErrorThatNamesNoRequest() throws {
    let setup = try Setup { _ in ["id": NSNull(), "error": ["code": "request_too_large", "message": "Too large."]] }
    let result = try setup.server.call("press", ["app": "Notes", "element": 1])
    #expect(result["isError"] as? Bool == true)
    #expect(textOf(result).hasPrefix("helper_stopped"))
  }

  @Test func reportsAHelperThatDoesNotAnswerInTimeAndConnectsAgainAfterwards() throws {
    let home = TemporaryHome()
    let helper = try FakeHelper(home: home) { $0["method"] as? String == "press" ? nil : ["result": ["ok": true]] }
    let server = try ServerProcess(home: home, environment: ["HELPER_TEST_TIMEOUT": "1"])
    let result = try server.call("press", ["app": "Notes", "element": 1])
    #expect(textOf(result).hasPrefix("timeout:"))
    #expect(textOf(result).contains("may or may not have run"))
    #expect(textOf(try until { () -> Object? in
      let next = try? server.call("list_apps")
      return next?["isError"] as? Bool == true ? nil : next
    }).contains("ok"))
    #expect(helper.all("hello").count == 2)
  }

  // A helper that restarted has forgotten the session, so numbers from before must not name its new elements.
  @Test func numbersElementsFromANewRangeOnEveryNewConnection() throws {
    let setup = try Setup { _ in ["result": ["ok": true]] }
    _ = try setup.server.call("list_apps")
    setup.helper.disconnectAll()
    _ = try until { () -> Object? in
      let next = try? setup.server.call("list_apps")
      return next?["isError"] as? Bool == true ? nil : next
    }
    let hellos = setup.helper.all("hello").map { $0["params"] as? Object ?? [:] }
    #expect(hellos.count == 2)
    #expect(hellos[0]["session_id"] as? String == hellos[1]["session_id"] as? String)
    #expect(hellos[0]["first_element_number"] == nil)
    #expect((hellos[1]["first_element_number"] as? Int ?? 0) > 100_000)
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

  @Test(arguments: [SIGTERM, SIGINT, SIGHUP])
  func endsOnASignal(signal: Int32) throws {
    let setup = try Setup()
    _ = try setup.server.request("ping")
    kill(setup.server.process.processIdentifier, signal)
    let ended = try setup.server.waitForExit()
    #expect(ended.status == 0 && ended.reason == .exit)
  }
}
