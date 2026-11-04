// The MCP server against a fake helper: protocol, argument checks and error reporting.

import Foundation
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



  @Test func listsToolsWithSchemasThatRejectUnknownArguments() throws {
    let setup = try Setup()
    let tools = (try setup.server.request("tools/list")["result"] as! Object)["tools"] as! [Object]
    #expect(tools.map { $0["name"] as! String } == ["list_apps", "launch_app", "list_operations", "run_operation", "get_window_state", "screenshot", "press", "set_value", "type_text", "press_key", "scroll", "drag", "click_at"])
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
    _ = try until { setup.helper.first("cancel") }
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
