// Starts the helper app and talks to it over its Unix socket: one connection and one session per command.
// State (the socket, the requests waiting for a reply, their tickets) has one owner, a serial queue; reading the
// socket and waiting for replies happen off it, so a cancel or a disconnect is handled while a request runs.

import Foundation
import HelperLink

struct HelperFailure: Error {
  // nil for a failure of this command rather than an answer from the helper.
  let code: String?
  let message: String
}

// Names one request, so a client can cancel it later. Cancelled before it is sent, the request is never sent.
final class Ticket: @unchecked Sendable {
  fileprivate var id: Int?
  fileprivate var cancelled = false
  // Written to the socket, so a cancel has a request to name.
  fileprivate var sent = false
}

private let startTimeout: TimeInterval = 8
// Long enough for the slowest operation, such as a shortcut or an export.
let requestTimeout: TimeInterval = 200
private let quitWait: TimeInterval = 3
private let startLockStale: TimeInterval = 20

// One socket, read by its own thread. Replies go to the client's queue.
private final class SocketConnection: @unchecked Sendable {
  let descriptor: Int32
  private let writeLock = NSLock()
  // Set by the reader once the helper's side is gone; read and written on the client's queue.
  var closed = false

  // Nonblocking, so a write can give up at its deadline; the reader waits for data instead.
  init(descriptor: Int32) {
    self.descriptor = descriptor
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
  }

  // A write that the helper does not take by the deadline fails rather than hangs, however slowly it drains.
  func write(_ object: Any, deadline: Date = Date().addingTimeInterval(requestTimeout)) -> Bool {
    guard writeLock.lock(before: deadline) else { return false }
    defer { writeLock.unlock() }
    return writeAll(descriptor, jsonLine(object), deadline: deadline)
  }

  // Ends reads and writes; the reader thread then sees the end and reports it.
  func shut() { Darwin.shutdown(descriptor, SHUT_RDWR) }
}

private func connectSocket(_ path: String) -> Int32? {
  let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else { return nil }
  var noSignal: Int32 = 1
  setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
    close(descriptor)
    return nil
  }
  withUnsafeMutableBytes(of: &address.sun_path) { raw in
    for (index, byte) in bytes.enumerated() { raw[index] = byte }
  }
  let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  guard connected == 0 else {
    close(descriptor)
    return nil
  }
  return descriptor
}

final class HelperClient: @unchecked Sendable {
  private let directories: Directories
  // For tests with a helper they started themselves: nothing is started or replaced.
  private let managesHelper: Bool
  // The app build this command belongs to, read when the command started: the app in the same bundle.
  private let expectedBuild: String?
  private let clientName: () -> String?
  let sessionId = UUID().uuidString.lowercased()

  private let queue = DispatchQueue(label: "helper-client")
  // Orders a request's write and its cancel, so a cancel never reaches the helper before the request it names.
  private let orderLock = NSLock()
  // One connection attempt at a time, shared by the callers that wait for it.
  private let connectLock = NSLock()
  private var current: SocketConnection?
  private var nextId = 1
  private var waiting: [Int: (socket: SocketConnection, finish: (Result<Any, HelperFailure>) -> Void)] = [:]

  init(directories: Directories, managesHelper: Bool, expectedBuild: String?, clientName: @escaping () -> String? = { nil }) {
    self.directories = directories
    self.managesHelper = managesHelper
    self.expectedBuild = expectedBuild
    self.clientName = clientName
  }

  // MARK: Requests

  func request(_ method: String, _ params: JSON = [:], ticket: Ticket? = nil) throws -> Any {
    let socket = try connection()
    return try send(socket, method, params, ticket: ticket)
  }

  // Ends the request the ticket names, running or queued, leaving the others alone.
  // Runs off the caller's thread, so a request stuck in its write never holds up the reader of the client's input.
  func cancel(_ ticket: Ticket?) {
    guard let ticket else { return }
    DispatchQueue.global().async { self.sendCancel(ticket) }
  }

  private func sendCancel(_ ticket: Ticket) {
    guard orderLock.lock(before: Date().addingTimeInterval(requestTimeout)) else { return }
    defer { orderLock.unlock() }
    let target: (Int, SocketConnection)? = queue.sync {
      ticket.cancelled = true
      guard ticket.sent, let id = ticket.id, let socket = current else { return nil }
      return (id, socket)
    }
    if let (id, socket) = target { _ = socket.write(["method": "cancel", "params": ["id": id]]) }
  }

  func close() {
    queue.sync { current }?.shut()
  }

  private func send(_ socket: SocketConnection, _ method: String, _ params: JSON, ticket: Ticket?) throws -> Any {
    let done = DispatchSemaphore(value: 0)
    var outcome: Result<Any, HelperFailure>?
    let id: Int = try queue.sync {
      if ticket?.cancelled == true { throw HelperFailure(code: "cancelled", message: "The request was cancelled.") }
      let id = nextId
      nextId += 1
      ticket?.id = id
      waiting[id] = (socket, { result in
        outcome = result
        done.signal()
      })
      return id
    }
    // One deadline covers waiting for the order lock, the write and the reply.
    let due = Date().addingTimeInterval(requestTimeout)
    let deadline = Int(due.timeIntervalSince1970 * 1000)
    // Cancelled between taking its id and being written, a request is never written.
    if orderLock.lock(before: due) {
      if queue.sync(execute: { ticket?.cancelled == true }) {
        finish(id, .failure(HelperFailure(code: "cancelled", message: "The request was cancelled.")))
      } else if socket.write(["id": id, "method": method, "params": params, "deadline": deadline], deadline: due) {
        queue.sync { ticket?.sent = true }
      } else {
        finish(id, .failure(stoppedFailure))
        socket.shut()
      }
      orderLock.unlock()
    }
    if done.wait(wallTimeout: .now() + max(0, due.timeIntervalSinceNow)) == .timedOut {
      // Later requests must not run behind one whose caller has given up.
      finish(id, .failure(HelperFailure(code: "timeout", message: "The helper did not answer \(method) in time. It may or may not have run.")))
      socket.shut()
      done.wait()
    }
    switch outcome! {
    case .success(let result): return result
    case .failure(let failure): throw failure
    }
  }

  // Completes a request once: a reply, a timeout and a disconnect may race, and only the first counts.
  private func finish(_ id: Int, _ result: Result<Any, HelperFailure>) {
    let pending = queue.sync { waiting.removeValue(forKey: id) }
    pending?.finish(result)
  }

  private let stoppedFailure = HelperFailure(code: "helper_stopped", message: "The helper stopped. The action may or may not have run; read the state before trying again.")

  // MARK: The connection

  private func attach(_ descriptor: Int32) -> SocketConnection {
    let socket = SocketConnection(descriptor: descriptor)
    let thread = Thread { [weak self] in self?.read(socket) }
    thread.start()
    return socket
  }

  private func read(_ socket: SocketConnection) {
    var framer = LineFramer()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
      let count = readAvailable(socket.descriptor, into: &buffer)
      guard count > 0 else { break }
      for line in framer.lines(in: Data(buffer[0..<count])) {
        guard let reply = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSON, let id = reply["id"] as? Int else { continue }
        if let error = reply["error"] as? JSON {
          finish(id, .failure(HelperFailure(code: error["code"] as? String ?? "error", message: error["message"] as? String ?? "")))
        } else {
          finish(id, .success(reply["result"] ?? NSNull()))
        }
      }
    }
    // Only this socket's requests fail; a newer connection keeps its own.
    let failed: [(Result<Any, HelperFailure>) -> Void] = queue.sync {
      socket.closed = true
      if current === socket { current = nil }
      let mine = waiting.filter { $0.value.socket === socket }
      for id in mine.keys { waiting.removeValue(forKey: id) }
      return mine.values.map(\.finish)
    }
    for finish in failed { finish(.failure(stoppedFailure)) }
    Darwin.close(socket.descriptor)
  }

  // A helper that goes away right after the handshake leaves no closed socket behind: the next attempt connects
  // again, and only a second loss in a row is reported.
  private func connection() throws -> SocketConnection {
    try connectLock.withLock {
      if let socket = queue.sync(execute: { current }) { return socket }
      for _ in 0..<2 {
        let socket = try establish()
        let published = queue.sync { () -> Bool in
          guard !socket.closed else { return false }
          current = socket
          return true
        }
        if published { return socket }
      }
      throw stoppedFailure
    }
  }

  private func hello(_ socket: SocketConnection) throws -> JSON {
    var params: JSON = ["session_id": sessionId]
    if let name = clientName() { params["client_name"] = name }
    return try send(socket, "hello", params, ticket: nil) as? JSON ?? [:]
  }

  private func establish() throws -> SocketConnection {
    guard let descriptor = connectSocket(directories.socketPath) else {
      guard managesHelper else { throw HelperFailure(code: nil, message: "No helper listens on \(directories.socketPath)") }
      return try startHelper()
    }
    let socket = attach(descriptor)
    let reply = try hello(socket)
    guard managesHelper, let expectedBuild, reply["build"] as? String != expectedBuild else { return socket }
    // The helper runs another build. Only when the installed app is this command's own build is the helper
    // stale and replaced; otherwise this command is the stale one, and it stops nothing that others use.
    guard installedBuild() == expectedBuild else {
      socket.shut()
      throw differsFromInstalled()
    }
    return try withStartLock {
      _ = try? send(socket, "quit", [:], ticket: nil)
      socket.shut()
      waitForSocketToClose()
      return try startHelper(locked: true)
    }
  }

  private func installedBuild() -> String? {
    buildIdentity(ofExecutableAt: Product.installedAppPath + "/Contents/MacOS/" + Product.appExecutableName)
  }

  private func differsFromInstalled() -> HelperFailure {
    HelperFailure(code: nil, message: "This \(Product.commandName) command belongs to another build than the installed \(Product.appName). Restart this session, or run: \(commandHint()) setup")
  }

  private func waitForSocketToClose() {
    let started = Date()
    while Date().timeIntervalSince(started) < quitWait {
      guard let descriptor = connectSocket(directories.socketPath) else { return }
      Darwin.close(descriptor)
      Thread.sleep(forTimeInterval: 0.05)
    }
  }

  // Started through LaunchServices, so macOS treats the app as its own process for its grants, never as part of
  // the client that started this command.
  private func startHelper(locked: Bool = false) throws -> SocketConnection {
    if installedBuild() != expectedBuild, expectedBuild != nil { throw differsFromInstalled() }
    let launch = { () throws -> SocketConnection in
      if let descriptor = connectSocket(self.directories.socketPath) { return self.attach(descriptor) }
      try runProcess("/usr/bin/open", ["-g", "-j", Product.installedAppPath, "--args", Product.backgroundArgument], timeout: 15)
      let started = Date()
      while Date().timeIntervalSince(started) < startTimeout {
        if let descriptor = connectSocket(self.directories.socketPath) { return self.attach(descriptor) }
        Thread.sleep(forTimeInterval: 0.1)
      }
      throw HelperFailure(code: nil, message: "The helper did not start. Run: \(commandHint()) doctor")
    }
    let socket = try locked ? launch() : withStartLock(launch)
    let reply = try hello(socket)
    if let expectedBuild, reply["build"] as? String != expectedBuild {
      socket.shut()
      throw differsFromInstalled()
    }
    return socket
  }

  // One start at a time: a second open of a running app counts as the user reopening it, which shows its window
  // and takes focus.
  private func withStartLock<T>(_ action: () throws -> T) throws -> T {
    try ensurePrivateDirectory(directories.state)
    let lock = directories.state + "/start.lock"
    let started = Date()
    while mkdir(lock, 0o700) != 0 {
      if let modified = (try? FileManager.default.attributesOfItem(atPath: lock))?[.modificationDate] as? Date,
         Date().timeIntervalSince(modified) > startLockStale {
        rmdir(lock)
      }
      if Date().timeIntervalSince(started) > startLockStale * 2 { throw HelperFailure(code: nil, message: "\(lock) is held") }
      Thread.sleep(forTimeInterval: 0.1)
    }
    defer { rmdir(lock) }
    return try action()
  }
}
