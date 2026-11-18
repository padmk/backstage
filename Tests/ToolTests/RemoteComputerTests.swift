// Calls with `computer`, through a stand-in for ssh that runs a second command against a fake helper of its own, as
// the installed app on another Mac would answer: the list of Macs, one connection per Mac, reconnecting, cancelling
// and a connection lost during a call.

import Darwin
import Foundation
import Testing
@testable import Tool

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

  init(allowed: Bool = true, timeout: String = "", remote respond: @escaping @Sendable (Object) -> Object? = { _ in ["result": ["apps": [] as [Any]] as Object] }) throws {
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
      HOME='\(remoteHome.path)' HELPER_TEST_HOME='\(remoteHome.path)' HELPER_TEST_TIMEOUT= exec '\(commandBinary)' mcp
      """
    let ssh = home.path + "/ssh"
    try script.write(toFile: ssh, atomically: true, encoding: .utf8)
    chmod(ssh, 0o755)
    // An empty timeout keeps the default; the other Mac's server always keeps it.
    server = try ServerProcess(home: home, environment: ["HELPER_TEST_SSH": ssh, "HELPER_TEST_TIMEOUT": timeout])
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
  // A request that times out ends its link in the same step: the others waiting fail at once, and no later request
  // registers on the link, so none is sent over a connection that is going away.
  @Test func aTimedOutLinkTakesNoMoreRequests() throws {
    let calls = LinkCalls()
    var timedOutAnswered = false
    var otherAnswer: JSON?? = .none
    let timedOut = try #require(calls.register { _ in timedOutAnswered = true })
    _ = try #require(calls.register { otherAnswer = .some($0) })
    calls.end(except: timedOut)
    #expect(!calls.isOpen)
    #expect(!timedOutAnswered)
    #expect(otherAnswer.map { $0 == nil } == true)
    #expect(calls.register { _ in } == nil)
  }

  // A write in progress when its link ends writes nothing more. The stand-in answers the handshake, ignores SIGTERM
  // as an ssh still shutting down may, and starts reading only once the test says so, after the link has ended.
  @Test func aWriteInProgressStopsWhenItsLinkEnds() throws {
    let home = TemporaryHome()
    let received = home.path + "/received"
    let pidFile = home.path + "/stand-in.pid"
    let go = home.path + "/go"
    let script = """
      #!/bin/sh
      trap '' TERM
      echo $$ > '\(pidFile)'
      read line
      echo '{"jsonrpc":"2.0","id":1,"result":{}}'
      while [ ! -e '\(go)' ]; do sleep 0.02; done
      exec cat > '\(received)'
      """
    let ssh = home.path + "/ssh"
    try script.write(toFile: ssh, atomically: true, encoding: .utf8)
    chmod(ssh, 0o755)
    let full = DispatchSemaphore(value: 0)
    let link = try RemoteLink(computer: "mbp", clientName: nil, elementNumberBase: 0, ssh: ssh, onFullPipe: { full.signal() })
    defer {
      // The stand-in ignores SIGTERM, so it is killed here; without its pid it never started.
      if let pid = (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
        kill(pid, SIGKILL)
      }
    }
    // Far more than a pipe holds, so the write waits for the other side to read.
    let large = String(repeating: "x", count: 4 << 20)
    let returned = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      // The request fails once the link ends; what matters is what reached the other side.
      _ = try? link.request("tools/call", ["name": "type_text", "arguments": ["text": large]], seconds: 10, lostMessage: "lost")
      returned.signal()
    }
    #expect(full.wait(timeout: .now() + 10) == .success)
    link.close()
    FileManager.default.createFile(atPath: go, contents: Data())
    // A write that went on after the end could return only once the other side had read nearly all of it.
    #expect(returned.wait(timeout: .now() + 15) == .success)
    let size = (try FileManager.default.attributesOfItem(atPath: received)[.size] as? NSNumber)?.intValue ?? -1
    #expect(size >= 0 && size < 1 << 20, "\(size) bytes reached the other side")
  }

  // A call to another Mac already on its way when the command stops opens no connection there.
  @Test func aClosedSessionOpensNoConnectionToAnotherMac() throws {
    let home = TemporaryHome()
    let ran = home.path + "/ran"
    let ssh = home.path + "/ssh"
    try "#!/bin/sh\ntouch '\(ran)'\nexit 255\n".write(toFile: ssh, atomically: true, encoding: .utf8)
    chmod(ssh, 0o755)
    let remote = RemoteComputers(reached: [], generation: 0, ssh: ssh)
    remote.closeForGood()
    #expect {
      try remote.call("mbp", "list_apps", [:], clientName: nil, cancellation: RemoteCancellation())
    } throws: { ($0 as? HelperFailure)?.code == "stopping" }
    #expect(!FileManager.default.fileExists(atPath: ran))
  }

  // A connection that is still opening when the session is closed for good writes nothing more: its handshake stops,
  // and the call answers `stopping`. The stand-in ignores SIGTERM, logs every line, answers the handshake only once
  // told to, and notes when its input has been silent for 2 s after that answer.
  @Test func aSessionClosedWhileALinkOpensSendsNoMoreHandshake() throws {
    let home = TemporaryHome()
    let log = home.path + "/log"
    let gotInitialize = home.path + "/got-initialize"
    let go = home.path + "/go"
    let pidFile = home.path + "/stand-in.pid"
    let silent = home.path + "/silent"
    let script = """
      #!/bin/sh
      trap '' TERM
      echo $$ > '\(pidFile)'
      read line
      echo "$line" >> '\(log)'
      touch '\(gotInitialize)'
      while [ ! -e '\(go)' ]; do sleep 0.02; done
      echo '{"jsonrpc":"2.0","id":1,"result":{}}'
      while read -t 2 line; do echo "$line" >> '\(log)'; done
      touch '\(silent)'
      while true; do sleep 1; done
      """
    let ssh = home.path + "/ssh"
    try script.write(toFile: ssh, atomically: true, encoding: .utf8)
    chmod(ssh, 0o755)
    defer {
      // Without its pid the stand-in never started.
      if let pid = (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
        kill(pid, SIGKILL)
      }
    }
    let remote = RemoteComputers(reached: [], generation: 0, ssh: ssh)
    let outcome = ThreadOutcome()
    let returned = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      do {
        _ = try remote.call("mbp", "list_apps", [:], clientName: nil, cancellation: RemoteCancellation())
        outcome.set(code: "success")
      } catch {
        outcome.set(error)
      }
      returned.signal()
    }
    try until { FileManager.default.fileExists(atPath: gotInitialize) ? true : nil }
    remote.closeForGood()
    FileManager.default.createFile(atPath: go, contents: Data())
    #expect(returned.wait(timeout: .now() + 10) == .success)
    #expect(outcome.code == "stopping")
    // A handshake that went on would have written within moments of the answer, before the 2 s of silence.
    try until { FileManager.default.fileExists(atPath: silent) ? true : nil }
    let lines = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 1, "\(lines)")
  }

  // A write checks its deadline before every chunk, so one past its time writes nothing, however much room there is.
  @Test func aWritePastItsDeadlineWritesNothing() throws {
    var ends: [Int32] = [0, 0]
    #expect(pipe(&ends) == 0)
    defer { close(ends[0]); close(ends[1]) }
    _ = fcntl(ends[1], F_SETFL, fcntl(ends[1], F_GETFL) | O_NONBLOCK)
    let calls = LinkCalls()
    #expect(!calls.write(ends[1], Data("late\n".utf8), deadline: Date().addingTimeInterval(-1)))
    var waiting: Int32 = 0
    _ = ioctl(ends[0], bytesWaitingRequest, &waiting)
    #expect(waiting == 0)
    #expect(calls.write(ends[1], Data("on time\n".utf8), deadline: Date().addingTimeInterval(5)))
  }

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

  @Test func closesAConnectionThatDidNotAnswerInTime() throws {
    // The other Mac's helper never answers the press, and this command waits 1 s plus its margin for it.
    let setup = try RemoteSetup(timeout: "1") { $0["method"] as? String == "press" ? nil : ["result": ["apps": [] as [Any]] as Object] }
    let late = try setup.server.call("press", ["app": "Notes", "element": 1, "computer": "mbp"])
    #expect(textOf(late).contains("did not answer"))
    let next = try setup.server.call("list_apps", ["computer": "mbp"])
    #expect(next["isError"] as? Bool != true)
    #expect(textOf(next).contains("opened again"))
    #expect(setup.sshRuns.count == 2)
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
