// The command's own pieces, called directly: the helper connection's socket, cancels and the setup lock.

import Darwin
import Foundation
import HelperLink
import Synchronization
import Testing
@testable import Tool

@Suite struct ClientTests {
  // The number of a closed socket goes to the next file opened; writes and shuts of the old one must not reach it.
  @Test func aClosedSocketNeverWritesToOrShutsTheFileThatGetsItsNumber() throws {
    // Far above the numbers other tests in this process use, so the next file placed there gets the closed number.
    var limit = rlimit()
    #expect(getrlimit(RLIMIT_NOFILE, &limit) == 0)
    let high = Int32(min(Int(limit.rlim_cur) - 16, 4000))
    var pair: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer { Darwin.close(pair[1]) }
    let number = fcntl(pair[0], F_DUPFD, high)
    Darwin.close(pair[0])
    let socket = SocketConnection(descriptor: number)
    socket.close()
    var other: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &other) == 0)
    let mine = fcntl(other[0], F_DUPFD, high)
    Darwin.close(other[0])
    defer { Darwin.close(mine); Darwin.close(other[1]) }
    try #require(mine == number)
    // A write the old socket's shut broke fails rather than end the test process.
    var noSignal: Int32 = 1
    setsockopt(mine, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    #expect(!socket.write(Data("old\n".utf8)))
    socket.shut()
    #expect(writeAll(mine, Data("new\n".utf8)))
    var buffer = [UInt8](repeating: 0, count: 16)
    #expect(Darwin.read(other[1], &buffer, buffer.count) == 4)
    #expect(Array(buffer[0..<4]) == Array("new\n".utf8))
  }

  // A server that is not serving handles no line and says nothing, not even for a line that is no JSON, and the
  // helper hears nothing.
  @Test func aLineWhileNotServingGetsNoReply() throws {
    let home = TemporaryHome()
    let helper = try FakeHelper(home: home)
    var output: [Int32] = [0, 0]
    #expect(pipe(&output) == 0)
    // Never closed: a call still running when the test ends may write its reply, and a closed number could by then
    // belong to another test in this process, such as a script's input.
    let server = MCPServer(directories: Directories(testHome: home.path), managesHelper: false, expectedBuild: nil, resumed: nil,
                           lifecycle: ServerLifecycle(), output: output[1])
    server.handle(line: "{broken")
    server.handle(line: line(["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "list_apps", "arguments": [:] as Object]]))
    #expect(server.flush())
    var waiting: Int32 = 0
    _ = ioctl(output[0], bytesWaitingRequest, &waiting)
    #expect(waiting == 0)
    #expect(helper.requests.isEmpty)
  }

  // A call admitted while serving that is still opening its connection when the stop begins never reaches the helper:
  // the stop closes the connections in the same step.
  @Test func aStopClosesTheConnectionOfACallAlreadyAdmitted() throws {
    let home = TemporaryHome()
    let helper = try FakeHelper(home: home, helloDelay: 0.5)
    var output: [Int32] = [0, 0]
    #expect(pipe(&output) == 0)
    // Never closed: a call still running when the test ends may write its reply, and a closed number could by then
    // belong to another test in this process, such as a script's input.
    let lifecycle = ServerLifecycle()
    let server = MCPServer(directories: Directories(testHome: home.path), managesHelper: false, expectedBuild: nil, resumed: nil,
                           lifecycle: lifecycle, output: output[1])
    #expect(lifecycle.transition(.attach(server)) != nil)
    server.handle(line: line(["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": ["name": "list_apps", "arguments": [:] as Object]]))
    try until { helper.all("hello").count == 1 ? true : nil }
    #expect(lifecycle.transition(.stop) != nil)
    let reply = try #require(readLine(output[0], timeout: 5))
    #expect(textOf(reply["result"] as? Object ?? [:]).hasPrefix("stopping"), "\(reply)")
    #expect(helper.first("list_apps") == nil)
  }

  // A close shuts a connection that is still opening, with its hello on the way, before it returns: the helper sees
  // that connection end long before it would answer, and nothing more is written over it.
  @Test func aCloseShutsAConnectionStillOpening() throws {
    let home = TemporaryHome()
    let helper = try FakeHelper(home: home, helloDelay: 3)
    let client = HelperClient(directories: Directories(testHome: home.path), managesHelper: false, expectedBuild: nil)
    let failure = ThreadOutcome()
    Thread.detachNewThread {
      do { _ = try client.request("list_apps") } catch { failure.set(error) }
    }
    try until { helper.all("hello").count == 1 ? true : nil }
    client.close()
    try until(timeout: 1.5) { helper.connectionsEnded == 1 ? true : nil }
    try until { failure.code == "stopping" ? true : nil }
    #expect(helper.requests.count == 1)
  }

  // A call already on its way when the command stops must not open a connection and reach the helper.
  @Test func aClosedClientSendsNothingAndSaysItIsStopping() throws {
    let home = TemporaryHome()
    let helper = try FakeHelper(home: home)
    let client = HelperClient(directories: Directories(testHome: home.path), managesHelper: false, expectedBuild: nil)
    client.close()
    #expect { try client.request("list_apps") } throws: { ($0 as? HelperFailure)?.code == "stopping" }
    // Not even a connection opens, so the helper spends no slot on a command that is going away.
    #expect(helper.connectionsMade == 0)
    #expect(helper.requests.isEmpty)
  }

  // A handoff right after a cancel reads the ticket at once, so the cancel must have marked it by then.
  @Test func aCancelMarksItsTicketBeforeItReturns() {
    let home = TemporaryHome()
    let client = HelperClient(directories: Directories(testHome: home.path), managesHelper: false, expectedBuild: nil)
    for _ in 0..<50 {
      let ticket = Ticket()
      client.cancel(ticket)
      #expect(client.isCancelled(ticket))
    }
  }

  // The process's phases: a stop that began first refuses the attach, so nothing reads input, and once a stop has
  // begun no handoff execs and none goes back to serving.
  @Test func aStopRefusesTheAttachAndAnyLaterExec() {
    let home = TemporaryHome()
    let directories = Directories(testHome: home.path)
    let stopped = ServerLifecycle()
    let early = MCPServer(directories: directories, managesHelper: false, expectedBuild: nil, resumed: nil, lifecycle: stopped)
    #expect(stopped.transition(.stop) != nil)
    #expect(stopped.transition(.attach(early)) == nil)
    #expect(!stopped.serves)

    let lifecycle = ServerLifecycle()
    let server = MCPServer(directories: directories, managesHelper: false, expectedBuild: nil, resumed: nil, lifecycle: lifecycle)
    #expect(lifecycle.transition(.beginHandoff) == nil)
    #expect(lifecycle.transition(.attach(server)) != nil)
    #expect(lifecycle.serves)
    #expect(lifecycle.transition(.beginHandoff) != nil)
    #expect(!lifecycle.serves)
    var execs = 0
    #expect(lifecycle.execHandoff { execs += 1 })
    // An exec that failed goes back to serving.
    #expect(lifecycle.transition(.endHandoff) != nil)
    #expect(lifecycle.serves)
    #expect(lifecycle.transition(.beginHandoff) != nil)
    #expect(lifecycle.transition(.stop) != nil)
    #expect(!lifecycle.execHandoff { execs += 1 })
    #expect(lifecycle.transition(.endHandoff) == nil)
    #expect(lifecycle.transition(.stop) == nil)
    #expect(execs == 1)
  }

  // A lock held past the wait's bound: no pause between tries runs past that bound, so the wait ends there and not at
  // the next 0.1 s try. The pauses are recorded, not timed, so a slow machine changes nothing.
  @Test func aFileLockPausesNoLongerThanItsBound() throws {
    let home = TemporaryHome()
    let path = home.path + "/lock"
    let holder = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    #expect(holder >= 0 && flock(holder, LOCK_EX) == 0)
    defer { close(holder) }
    var pauses: [TimeInterval] = []
    var ran = false
    #expect(throws: HelperFailure.self) {
      try withFileLock(path, held: "held", waiting: 0.025, sleep: { pauses.append($0); Thread.sleep(forTimeInterval: $0) }) { ran = true }
    }
    #expect(!ran)
    #expect(!pauses.isEmpty && pauses.allSatisfy { $0 <= 0.025 }, "\(pauses)")
  }

  // A lock that frees only after the wait's bound is not used: here the pause oversleeps the bound, as on a slow
  // machine, and the lock is let go meanwhile, so the next try takes it too late.
  @Test func aFileLockTakenAfterItsBoundIsNotUsed() throws {
    let home = TemporaryHome()
    let path = home.path + "/lock"
    let holder = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    #expect(holder >= 0 && flock(holder, LOCK_EX) == 0)
    var ran = false
    var released = false
    #expect(throws: HelperFailure.self) {
      try withFileLock(path, held: "held", waiting: 0.025, sleep: { _ in
        Thread.sleep(forTimeInterval: 0.05)
        if !released { close(holder) }
        released = true
      }) { ran = true }
    }
    if !released { close(holder) }
    #expect(!ran)
  }

  // Each round starts from a lock a setup that was killed left behind; one setup at a time all the same.
  @Test func oneSetupHoldsTheLockAtATime() throws {
    let home = TemporaryHome()
    let installer = Installer(directories: Directories(testHome: home.path))
    let gone = Process()
    gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try gone.run()
    gone.waitUntilExit()
    let inside = Counter()
    for _ in 0..<6 {
      let abandoned = home.path + "/setup.lock"
      // The lock from the round before may still be there, which is the state wanted.
      try? FileManager.default.createDirectory(atPath: abandoned, withIntermediateDirectories: false)
      try String(gone.processIdentifier).write(toFile: abandoned + "/owner", atomically: true, encoding: .utf8)
      // Threads of their own, since waiting for the lock on Dispatch's threads would starve other tests in this process.
      let finished = DispatchSemaphore(value: 0)
      for _ in 0..<8 {
        Thread.detachNewThread {
          // A failure to take the lock shows as no entry, which the count below reports.
          try? installer.withSetupLock {
            inside.enter()
            Thread.sleep(forTimeInterval: 0.002)
            inside.leave()
          }
          finished.signal()
        }
      }
      for _ in 0..<8 { finished.wait() }
    }
    #expect(inside.most == 1)
    #expect(inside.entries == 48)
  }
}

// How many are inside at once, at most, and how many entered.
private final class Counter: Sendable {
  private struct State {
    var now = 0
    var most = 0
    var entries = 0
  }

  private let state = Mutex(State())

  func enter() {
    state.withLock {
      $0.now += 1
      $0.entries += 1
      $0.most = max($0.most, $0.now)
    }
  }

  func leave() { state.withLock { $0.now -= 1 } }
  var most: Int { state.withLock { $0.most } }
  var entries: Int { state.withLock { $0.entries } }
}

// What a call on another thread ended with, as a code: a HelperFailure's, or one the test sets; read by the test.
final class ThreadOutcome: Sendable {
  private let value = Mutex<String?>(nil)
  func set(_ error: any Error) { set(code: (error as? HelperFailure)?.code ?? "\(error)") }
  func set(code: String?) { value.withLock { $0 = code } }
  var code: String? { value.withLock { $0 } }
}
