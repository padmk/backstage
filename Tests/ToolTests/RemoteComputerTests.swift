// Calls with `computer`, through a stand-in for ssh that runs a second command against a fake helper of its own, as
// the installed app on another Mac would answer: the list of Macs, one connection per Mac, reconnecting, cancelling
// and a connection lost during a call.

import Darwin
import Foundation
import Testing

private var notApproved: Object { ["error": ["code": "computer_not_approved", "message": "mbp is not on the list"] as Object] }

// This Mac's helper and command, and the other Mac's helper, reached through the ssh stand-in.
private final class RemoteSetup {
  let home = TemporaryHome()
  let remoteHome = TemporaryHome()
  let helper: FakeHelper
  let remoteHelper: FakeHelper
  let server: ServerProcess
  let sshLog: String
  let remotePidFile: String

  init(allowed: Bool = true, remote respond: @escaping @Sendable (Object) -> Object? = { _ in ["result": ["apps": [] as [Any]] as Object] }) throws {
    let home = self.home
    helper = try FakeHelper(home: home) { request in
      guard request["method"] as? String == "require_computer" else { return ["result": [:] as Object] }
      return allowed ? ["result": ["allowed": true] as Object] : notApproved
    }
    remoteHelper = try FakeHelper(home: remoteHome, respond: respond)
    sshLog = home.path + "/ssh.log"
    remotePidFile = home.path + "/remote.pid"
    // The host is the argument after `--`; "down" stands for a Mac ssh cannot reach.
    let script = """
      #!/bin/sh
      echo "$*" >> '\(sshLog)'
      while [ "$1" != "--" ]; do shift; done
      if [ "$2" = "down" ]; then echo "ssh: connect to host down port 22: Connection refused" >&2; exit 255; fi
      echo $$ > '\(remotePidFile)'
      HOME='\(remoteHome.path)' HELPER_TEST_HOME='\(remoteHome.path)' exec '\(commandBinary)' mcp
      """
    let ssh = home.path + "/ssh"
    try script.write(toFile: ssh, atomically: true, encoding: .utf8)
    chmod(ssh, 0o755)
    server = try ServerProcess(home: home, environment: ["HELPER_TEST_SSH": ssh])
    _ = try server.initialize()
  }

  var sshRuns: [String] {
    // No log yet means ssh never ran.
    ((try? String(contentsOfFile: sshLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
  }

  // Ends the other Mac's server, as a dropped connection would.
  func dropConnection() throws {
    // No pid file yet means the other Mac's server has not started; until tries again.
    let pid = try until { (try? String(contentsOfFile: remotePidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    kill(pid, SIGKILL)
  }
}

@Suite struct RemoteComputerTests {
  @Test func refusesAMacThatIsNotOnTheListWithoutRunningSsh() throws {
    let setup = try RemoteSetup(allowed: false)
    let result = try setup.server.call("list_apps", ["computer": "mbp"])
    #expect(result["isError"] as? Bool == true)
    #expect(textOf(result).contains("computer_not_approved"))
    #expect((setup.helper.first("require_computer")?["params"] as? Object)?["computer"] as? String == "mbp")
    #expect(setup.sshRuns.isEmpty)
  }

  @Test func refusesANameSshCouldReadAsAnOption() throws {
    let setup = try RemoteSetup()
    let result = try setup.server.call("list_apps", ["computer": "-oProxyCommand=x"])
    #expect(textOf(result).contains("invalid_arguments"))
    #expect(setup.helper.first("require_computer") == nil)
    #expect(setup.sshRuns.isEmpty)
  }

  @Test func runsCallsThereOverOneConnectionWithoutTheComputerArgument() throws {
    let setup = try RemoteSetup()
    for _ in 0..<2 {
      let result = try setup.server.call("list_apps", ["computer": "mbp"])
      #expect(result["isError"] as? Bool != true)
      #expect(!textOf(result).contains("opened again"))
    }
    let calls = try until { () -> [Object]? in
      let found = setup.remoteHelper.all("list_apps")
      return found.count == 2 ? found : nil
    }
    #expect(calls.allSatisfy { ($0["params"] as? Object)?["computer"] == nil })
    #expect(setup.sshRuns.count == 1)
    #expect(setup.sshRuns.first?.contains("-o BatchMode=yes") == true)
    #expect(setup.sshRuns.first?.contains("-- mbp ") == true)
    #expect(setup.helper.all("list_apps").isEmpty)
  }

  @Test func reportsAMacSshCannotReach() throws {
    let setup = try RemoteSetup()
    let result = try setup.server.call("list_apps", ["computer": "down"])
    #expect(result["isError"] as? Bool == true)
    #expect(textOf(result).contains("computer_unreachable"))
    #expect(textOf(result).contains("Connection refused"))
  }

  @Test func numbersElementsApartAndSaysSoOnceWhenTheConnectionOpensAgain() throws {
    let setup = try RemoteSetup()
    _ = try setup.server.call("list_apps", ["computer": "mbp"])
    try setup.dropConnection()
    try until { setup.remoteHelper.all("list_apps").count == 1 ? true : nil }
    let reopened = try until { () -> Object? in
      // A call before the connection opened again fails and is tried again.
      let result = try? setup.server.call("list_apps", ["computer": "mbp"])
      return result.flatMap { textOf($0).contains("opened again") ? $0 : nil }
    }
    #expect(reopened["isError"] as? Bool != true)
    #expect(setup.sshRuns.count == 2)
    // The second session there numbers from a range of its own, so an old number names no element of it.
    let hellos = setup.remoteHelper.all("hello").map { ($0["params"] as? Object)?["first_element_number"] as? Int ?? 1 }
    #expect(hellos.first == 1)
    #expect((hellos.last ?? 0) > 1_000_000_000)
    let next = try setup.server.call("list_apps", ["computer": "mbp"])
    #expect(!textOf(next).contains("opened again"))
  }

  @Test func saysAnActionMayHaveRunWhenTheConnectionEndsDuringIt() throws {
    // The other Mac's helper never answers the press, so the call is still running when the connection drops.
    let setup = try RemoteSetup { $0["method"] as? String == "press" ? nil : ["result": ["apps": [] as [Any]] as Object] }
    _ = try setup.server.call("list_apps", ["computer": "mbp"])
    setup.server.write(line(["jsonrpc": "2.0", "id": 900, "method": "tools/call",
                             "params": ["name": "press", "arguments": ["app": "Notes", "element": 1, "computer": "mbp"]] as Object]))
    try until { setup.remoteHelper.first("press") }
    try setup.dropConnection()
    let reply = try until { setup.server.received.first { ($0["id"] as? Int) == 900 } }
    let result = reply["result"] as? Object ?? [:]
    #expect(result["isError"] as? Bool == true)
    #expect(textOf(result).contains("outcome_unknown"))
  }

  @Test func passesACancellationOnToTheOtherMac() throws {
    let setup = try RemoteSetup { $0["method"] as? String == "press" ? nil : ["result": ["apps": [] as [Any]] as Object] }
    setup.server.write(line(["jsonrpc": "2.0", "id": 901, "method": "tools/call",
                             "params": ["name": "press", "arguments": ["app": "Notes", "element": 1, "computer": "mbp"]] as Object]))
    let press = try until { setup.remoteHelper.first("press") }
    setup.server.write(line(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 901] as Object]))
    let cancel = try until { setup.remoteHelper.first("cancel") }
    #expect((cancel["params"] as? Object)?["id"] as? Int == press["id"] as? Int)
  }
}
