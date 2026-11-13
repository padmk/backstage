// A request's deadline holds while it waits and before each effect.

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
}
