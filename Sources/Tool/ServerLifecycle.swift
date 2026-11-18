// The life of the `backstage mcp` process as one phase, changed only by `transition` under one lock: it starts, then
// serves a client, may hand that session to the installed command, and stops once. Everything that must agree with
// the phase (whether input is read, whether a handoff may exec, whether a stop has begun) reads it here.

import Foundation
import HelperLink
import Synchronization

enum ServerPhase {
  // Before the server exists: its stop only ends the process.
  case starting
  // Reading the client's input and answering it.
  case serving(MCPServer)
  // Input stays unread while the session is prepared for the installed command and, last, that command is exec'd.
  case handingOff(MCPServer)
  // A stop has begun; the process ends. No phase follows it.
  case stopping
}

extension ServerPhase {
  var server: MCPServer? {
    switch self {
    case .serving(let server), .handingOff(let server): server
    case .starting, .stopping: nil
    }
  }
}

enum ServerEvent {
  // The server exists and may serve; refused once a stop has begun.
  case attach(MCPServer)
  case beginHandoff
  // A handoff that gave up, or whose exec failed: serving goes on.
  case endHandoff
  case stop
}

// The phase an event leads to from `phase`, or nil when it does not apply there.
func nextPhase(_ phase: ServerPhase, _ event: ServerEvent) -> ServerPhase? {
  switch (phase, event) {
  case (.stopping, _): nil
  case (_, .stop): .stopping
  case (.starting, .attach(let server)): .serving(server)
  case (.serving(let server), .beginHandoff): .handingOff(server)
  case (.handingOff(let server), .endHandoff): .serving(server)
  default: nil
  }
}

// Tests with HELPER_TEST_HOME may hold a stop this many seconds after it began, before the process ends, and a
// handoff as long right before its exec; each writes a marker file in the test home, holding the command's
// arguments, when its hold begins.
private let testHolds: (stop: TimeInterval?, exec: TimeInterval?, home: String?) = {
  let environment = ProcessInfo.processInfo.environment
  guard let home = environment["HELPER_TEST_HOME"] else { return (nil, nil, nil) }
  let seconds = { (name: String) in environment[name].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } }
  return (seconds("HELPER_TEST_STOP_DELAY"), seconds("HELPER_TEST_EXEC_DELAY"), home)
}()

private func testHold(_ seconds: TimeInterval?, marker: String) {
  guard let seconds, let home = testHolds.home else { return }
  // The arguments say which command holds: a command a handoff started has the resume argument.
  FileManager.default.createFile(atPath: home + "/" + marker, contents: Data(CommandLine.arguments.joined(separator: " ").utf8))
  Thread.sleep(forTimeInterval: seconds)
}

final class ServerLifecycle: Sendable {
  private let phase = Mutex<ServerPhase>(.starting)

  // Applies `event` if it leads anywhere from the current phase; returns the phase it left, or nil when refused.
  // Entering `stopping` closes the server's connections to the helper and to other Macs for good in the same step,
  // so no call admitted before, and no call at all after, reaches either once a stop has begun.
  @discardableResult
  func transition(_ event: ServerEvent) -> ServerPhase? {
    phase.withLock { phase in
      guard let next = nextPhase(phase, event) else { return nil }
      defer { phase = next }
      if case .stopping = next { phase.server?.close() }
      return phase
    }
  }

  // Input is read, and a request is handled, only while serving: not before the server is attached, nor during a
  // handoff or a stop. Resumed input, which a handoff passed on, is handled the same way.
  var serves: Bool {
    phase.withLock { phase in
      if case .serving = phase { return true }
      return false
    }
  }

  // Runs a handoff's exec only while the handoff is the phase, holding the lock a stop's transition takes, so either
  // the stop or the exec comes first. A stop signal that arrives during the exec stays pending into the installed
  // command, which then stops. An exec that works never returns; false when a stop came first.
  func execHandoff(_ exec: () -> Void) -> Bool {
    phase.withLock { phase in
      guard case .handingOff = phase else { return false }
      testHold(testHolds.exec, marker: "exec-hold")
      exec()
      return true
    }
  }

  // Ends the process once, from whichever comes first: a signal, the end of input, a failed write. Later calls,
  // and one while another stop runs, return.
  func stop() {
    guard let left = transition(.stop) else { return }
    end(after: left)
  }

  // The rest of a stop whose transition was made, leaving `left`: the server closes and the process ends.
  func end(after left: ServerPhase) -> Never {
    testHold(testHolds.stop, marker: "stop-hold")
    // Its connections closed with the transition; what was sent to the client is written if it can be.
    let server = left.server
    // A client that stopped reading gets what it would not read cut off; the process ends regardless.
    _ = server?.flush()
    exit(0)
  }
}
