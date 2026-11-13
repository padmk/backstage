// A request's deadline holds while it waits and before each effect, and a reply's write ends at its own.

@testable import App
import Darwin
import Foundation
import Testing

// A connection on one end of a socket pair; the other end is the client, which the test may never read.
private final class SocketPair {
  let connection: Connection
  let client: Int32

  init() throws {
    var descriptors: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw TestFailure("socketpair failed") }
    connection = Connection(descriptor: descriptors[0])
    client = descriptors[1]
  }

  deinit {
    close(connection.descriptor)
    close(client)
  }
}

private func code(of error: any Error) -> String? { (error as? HelperError)?.code }

@Suite struct RequestDeadlineTests {
  // A request whose deadline has passed, while it waited for the app's lock or before, runs nothing under it.
  @Test func theAppLockRunsNothingPastTheDeadline() throws {
    let pair = try SocketPair()
    pair.connection.begin(generation: 0, id: "1", deadline: Date().addingTimeInterval(-1))
    var ran = false
    #expect { try AppLocks.with("com.example.deadline", connection: pair.connection) { ran = true } } throws: { code(of: $0) == "expired" }
    #expect(!ran)
  }

  @Test func aChildIsNotStartedPastTheDeadline() throws {
    let pair = try SocketPair()
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("deadline-\(UUID().uuidString)").path
    pair.connection.begin(generation: 0, id: "1", deadline: Date().addingTimeInterval(-1))
    #expect {
      try withCurrentConnection(pair.connection) { try runProcess("/usr/bin/touch", [marker], target: "touch", timeout: 30) }
    } throws: { code(of: $0) == "expired" }
    #expect(!FileManager.default.fileExists(atPath: marker))
  }

  // A child gets only the time its client still waits; stopped then, it may have acted, so the outcome is unknown
  // rather than a plain timeout.
  @Test func aChildEndsWithTheRequestsTimeLeft() throws {
    let pair = try SocketPair()
    pair.connection.begin(generation: 0, id: "1", deadline: Date().addingTimeInterval(1.5))
    let started = Date()
    #expect {
      try withCurrentConnection(pair.connection) { try runProcess("/bin/sleep", ["10"], target: "sleep", timeout: 30) }
    } throws: { code(of: $0) == "outcome_unknown" }
    #expect(Date().timeIntervalSince(started) < 4)
  }

  // A pid no process has, so the events the effects post reach nobody.
  private func noProcess() throws -> pid_t {
    let free = (90_000..<99_000).reversed().first { kill(pid_t($0), 0) == -1 && errno == ESRCH }
    return pid_t(try #require(free))
  }

  // The deadline is checked right before the effect, after the reads that prepare it, whatever they took.
  @Test func anEffectDoesNotStartPastTheDeadline() throws {
    let pair = try SocketPair()
    let pid = try noProcess()
    pair.connection.begin(generation: 0, id: "1", deadline: Date().addingTimeInterval(-1))
    let key = try KeyCombination.parse("return")
    #expect { try withCurrentConnection(pair.connection) { try postKey(key, pid: pid) } } throws: { code(of: $0) == "expired" }
    let target = PointerTarget(window: nil, origin: .zero)
    #expect {
      try withCurrentConnection(pair.connection) { try postClick(at: .zero, target: target, pid: pid, count: 1) }
    } throws: { code(of: $0) == "expired" }
  }

  // Once one effect may have begun, a cancel can no longer report that nothing was done.
  @Test func aStopAfterAnEffectBeganLeavesTheOutcomeUnknown() throws {
    let pair = try SocketPair()
    let pid = try noProcess()
    #expect(pair.connection.enqueue(id: "1"))
    pair.connection.begin(generation: 0, id: "1", deadline: nil)
    try withCurrentConnection(pair.connection) {
      try postKey(try KeyCombination.parse("tab"), pid: pid)
      pair.connection.cancel(requestId: "1")
      #expect { try postText("a", pid: pid) } throws: { code(of: $0) == "outcome_unknown" }
      #expect { try pair.connection.throwIfStopped() } throws: { code(of: $0) == "outcome_unknown" }
    }
    // The next request starts with nothing done.
    pair.connection.finish(id: "1")
    #expect(pair.connection.enqueue(id: "2"))
    pair.connection.begin(generation: 0, id: "2", deadline: nil)
    pair.connection.cancel(requestId: "2")
    #expect { try pair.connection.throwIfStopped() } throws: { code(of: $0) == "cancelled" }
  }

  // A client that stops reading must not hold the reply's write, and with it the connection's worker and a restart.
  @Test func aReplyToAClientThatStopsReadingGivesUpAtItsDeadline() throws {
    let pair = try SocketPair()
    let outcome = AsyncOutcome<Bool>()
    let connection = pair.connection
    Thread.detachNewThread {
      outcome.set(.success(sendReply(["id": 1, "result": String(repeating: "x", count: 8 << 20)], to: connection, within: 1)))
    }
    let result = try #require(outcome.wait(until: .now() + 10), "The write did not end")
    #expect(try result.get() == false)
  }
}
