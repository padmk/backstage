// Starts the helper app and talks to it over its Unix socket: one connection and one session per command.
// State (the socket, the requests waiting for a reply, their tickets) has one owner, a serial queue; reading the
// socket and waiting for replies happen off it, so a cancel or a disconnect is handled while a request runs.

import Foundation
import HelperLink
import Synchronization

struct HelperFailure: Error {
  // nil for a failure of this command rather than an answer from the helper.
  let code: String?
  let message: String
}

// Names one request, so a client can cancel it later. Cancelled before it is sent, the request is never sent.
// Unchecked: its fields are read and written only on the helper client's serial queue.
final class Ticket: @unchecked Sendable {
  fileprivate var id: Int?
  fileprivate var cancelled = false
  // Written to the socket, so a cancel has a request to name.
  fileprivate var sent = false
}

private let startTimeout: TimeInterval = 8
// Long enough for the slowest operation, such as a shortcut or an export. Tests with HELPER_TEST_HOME may shorten
// it with HELPER_TEST_TIMEOUT, in seconds.
let requestTimeout: TimeInterval = {
  let environment = ProcessInfo.processInfo.environment
  guard environment["HELPER_TEST_HOME"] != nil, let seconds = environment["HELPER_TEST_TIMEOUT"].flatMap(Double.init), seconds > 0 else { return 200 }
  return seconds
}()
private let quitWait: TimeInterval = 3

// One socket, read by its own thread. Replies go to the client's queue. The reader closes the descriptor, and only
// through `close`, so no write or shut reaches a number the system has since given to another file.
// Unchecked: writes hold `writeLock`, the descriptor's state is a Mutex, and `closed` is read and written only on the
// helper client's serial queue.
final class SocketConnection: @unchecked Sendable {
  let descriptor: Int32
  private let writeLock = NSLock()
  // Whether `close` has run; checked and changed together with every use of the descriptor but the reader's.
  private let descriptorClosed = Mutex(false)
  // Set by the reader once the helper's side is gone; read and written on the client's queue.
  var closed = false

  // Nonblocking, so a write can give up at its deadline; the reader waits for data instead.
  init(descriptor: Int32) {
    self.descriptor = descriptor
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
  }

  // A write that the helper does not take by the deadline fails rather than hangs, however slowly it drains.
  // Once closed, nothing is written.
  func write(_ line: Data, deadline: Date = Date().addingTimeInterval(requestTimeout)) -> Bool {
    guard writeLock.lock(before: deadline) else { return false }
    defer { writeLock.unlock() }
    guard !descriptorClosed.withLock({ $0 }) else { return false }
    return writeAll(descriptor, line, deadline: deadline)
  }

  // Ends reads and writes; the reader thread then sees the end and reports it. Does nothing once closed.
  func shut() {
    descriptorClosed.withLock { closed in
      if !closed { Darwin.shutdown(descriptor, SHUT_RDWR) }
    }
  }

  // Returns once no write is under way, as after `shut`, when a write in progress gives up at once.
  func waitForWrites() {
    writeLock.lock()
    writeLock.unlock()
  }

  // For the reader, after its last read. Shutting first ends a write in progress, which holds the write lock until
  // it gives up; the close then waits for it, so no write is under way on the number it frees.
  func close() {
    shut()
    writeLock.lock()
    defer { writeLock.unlock() }
    descriptorClosed.withLock { closed in
      guard !closed else { return }
      closed = true
      Darwin.close(descriptor)
    }
  }
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

// Unchecked: the connection, the requests waiting and the ids are read and written only on the serial `queue`, and
// the count of connections made only holding `connectLock`; `onOutdated` and `handoffGeneration` are set before
// the first request and only read after, and `elementNumberBase`, which an initialize may set at any time, is a Mutex.
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
  // Set by `close`, for good: from then on no connection opens and no request is sent.
  private var closedForGood = false
  // Connections that have not been published yet, from their connect to their publication or their end, so `close`
  // shuts them too.
  private var openingSockets: [ObjectIdentifier: SocketConnection] = [:]
  // Connections whose reader has seen the end and whose writer may still be finishing, until it has, so `close`
  // waits for them too.
  private var retiringSockets: [ObjectIdentifier: SocketConnection] = [:]
  private var nextId = 1
  private var waiting: [Int: (socket: SocketConnection, finish: (Result<Any, HelperFailure>) -> Void)] = [:]
  // Requests waiting for a connection, which have not reached any helper.
  private var awaitingConnection = Set<ObjectIdentifier>()
  // Called, holding the connection lock, when this command turns out to be an older build than the installed app;
  // it may replace this process with the installed command and then never returns.
  var onOutdated: (() -> Void)?
  // How many handoffs brought this session here, and how many connections this process has made: each connection
  // asks for element numbers of its own range, so a number read before a helper restart or a handoff never names
  // an element of the new helper.
  var handoffGeneration = 0
  // Where this session's numbers start when another Mac's command opened it again; the next connection uses it.
  var elementNumberBase: Int {
    get { numberBase.withLock { $0 } }
    set { numberBase.withLock { $0 = newValue } }
  }
  private let numberBase = Mutex(0)
  private var connectionsMade = 0

  init(directories: Directories, managesHelper: Bool, expectedBuild: String?, clientName: @escaping () -> String? = { nil }) {
    self.directories = directories
    self.managesHelper = managesHelper
    self.expectedBuild = expectedBuild
    self.clientName = clientName
  }

  // MARK: Requests

  func request(_ method: String, _ params: JSON = [:], ticket: Ticket? = nil) throws -> Any {
    let key = ticket.map(ObjectIdentifier.init)
    if let key { queue.sync { _ = awaitingConnection.insert(key) } }
    let socket: SocketConnection
    do {
      defer { if let key { queue.sync { _ = awaitingConnection.remove(key) } } }
      socket = try connection()
    }
    return try send(socket, method, params, ticket: ticket)
  }

  // Whether the request has not been sent anywhere yet and is waiting for a connection.
  func isAwaitingConnection(_ ticket: Ticket) -> Bool {
    queue.sync { awaitingConnection.contains(ObjectIdentifier(ticket)) }
  }

  func isCancelled(_ ticket: Ticket) -> Bool { queue.sync { ticket.cancelled } }

  // Ends the request the ticket names, running or queued, leaving the others alone.
  // The ticket is marked at once, so a handoff right after never passes the call on. The cancel for the helper is
  // written off the caller's thread, so a request stuck in its write never holds up the reader of the client's input,
  // and on a thread of its own, since work on a busy Dispatch queue can start seconds late.
  func cancel(_ ticket: Ticket?) {
    guard let ticket else { return }
    queue.sync { ticket.cancelled = true }
    Thread.detachNewThread { self.sendCancel(ticket) }
  }

  // Under the order lock, so a request written before the mark is seen as sent, and one checked after it is never written.
  private func sendCancel(_ ticket: Ticket) {
    guard orderLock.lock(before: Date().addingTimeInterval(requestTimeout)) else { return }
    defer { orderLock.unlock() }
    let target: (Int, SocketConnection)? = queue.sync {
      guard ticket.sent, let id = ticket.id, let socket = current else { return nil }
      return (id, socket)
    }
    if let (id, socket) = target { _ = socket.write(jsonLine(["method": "cancel", "params": ["id": id]])) }
  }

  // Ends this client for good, as when the command stops: a call that was already on its way gets `stopping` rather
  // than a new connection to the helper.
  // Returns once nothing more can be written to the helper: the published connection and those still opening are
  // shut, and a write in progress has given up.
  func close() {
    let sockets = queue.sync { () -> [SocketConnection] in
      closedForGood = true
      return (current.map { [$0] } ?? []) + Array(openingSockets.values) + Array(retiringSockets.values)
    }
    for socket in sockets {
      socket.shut()
      socket.waitForWrites()
    }
  }

  private func send(_ socket: SocketConnection, _ method: String, _ params: JSON, ticket: Ticket?) throws -> Any {
    let done = DispatchSemaphore(value: 0)
    var outcome: Result<Any, HelperFailure>?
    let id: Int = try queue.sync {
      if ticket?.cancelled == true { throw HelperFailure(code: "cancelled", message: "The request was cancelled.") }
      if closedForGood { throw stoppingFailure }
      // The reader has already failed this socket's requests, so one registered now would wait for its deadline.
      if socket.closed { throw stoppedFailure }
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
    let line = jsonLine(["id": id, "method": method, "params": params, "deadline": deadline])
    // Cancelled between taking its id and being written, a request is never written. Nor is one the helper would
    // refuse for its size: that refusal names no request, so it ends the connection for every other call.
    if orderLock.lock(before: due) {
      if queue.sync(execute: { ticket?.cancelled == true }) {
        finish(id, .failure(HelperFailure(code: "cancelled", message: "The request was cancelled.")))
      } else if line.count - 1 > maxFrameBytes {
        finish(id, .failure(HelperFailure(code: "request_too_large", message: "The request is larger than \(maxFrameBytes >> 20) MB, so it was not sent. Send less at once.")))
      } else if socket.write(line, deadline: due) {
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

  private let stoppingFailure = HelperFailure(code: "stopping", message: "This command is stopping, so the request was not sent.")
  private let stoppedFailure = HelperFailure(code: "helper_stopped", message: "The helper stopped. The action may or may not have run; read the state before trying again.")

  // MARK: The connection

  // Registers a new connection as opening, under the same state `close` sets, so one that a close came before is
  // ended unused and every other is shut by a close from then on.
  private func attach(_ descriptor: Int32) throws -> SocketConnection {
    let socket = SocketConnection(descriptor: descriptor)
    let admitted = queue.sync { () -> Bool in
      guard !closedForGood else { return false }
      openingSockets[ObjectIdentifier(socket)] = socket
      return true
    }
    guard admitted else {
      socket.close()
      throw stoppingFailure
    }
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
        // A line that is no reply, like an error that names no request, could belong to any of them; ending the
        // connection fails them all rather than leave one waiting for its deadline.
        guard let reply = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? JSON else {
          socket.shut()
          continue
        }
        guard let id = reply["id"] as? Int else {
          if reply["error"] != nil { socket.shut() }
          continue
        }
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
      openingSockets.removeValue(forKey: ObjectIdentifier(socket))
      retiringSockets[ObjectIdentifier(socket)] = socket
      let mine = waiting.filter { $0.value.socket === socket }
      for id in mine.keys { waiting.removeValue(forKey: id) }
      return mine.values.map(\.finish)
    }
    for finish in failed { finish(.failure(stoppedFailure)) }
    socket.close()
    // Its writer has finished, so a close has nothing left to wait for here.
    queue.sync { _ = retiringSockets.removeValue(forKey: ObjectIdentifier(socket)) }
  }

  // A helper that goes away right after the handshake leaves no closed socket behind: the next attempt connects
  // again, and only a second loss in a row is reported.
  private func connection() throws -> SocketConnection {
    try connectLock.withLock {
      let existing: SocketConnection? = try queue.sync {
        if closedForGood { throw stoppingFailure }
        return current
      }
      if let existing { return existing }
      for _ in 0..<2 {
        let socket: SocketConnection
        do {
          socket = try establish()
        } catch {
          // A connection a close ended while it opened sent no request.
          if queue.sync(execute: { closedForGood }) { throw stoppingFailure }
          throw error
        }
        // A close while this connection opened ends it before any request goes over it.
        let published = queue.sync { () -> Bool? in
          openingSockets.removeValue(forKey: ObjectIdentifier(socket))
          if closedForGood { return nil }
          guard !socket.closed else { return false }
          current = socket
          return true
        }
        guard let published else {
          socket.shut()
          throw stoppingFailure
        }
        if published { return socket }
      }
      throw stoppedFailure
    }
  }

  // Runs holding the connection lock, once for each new connection.
  private func hello(_ socket: SocketConnection) throws -> JSON {
    var params: JSON = ["session_id": sessionId]
    if let name = clientName() { params["client_name"] = name }
    // A helper that kept the session goes on with its numbers, from no lower than the new range's start.
    let range: Range<Int>
    do {
      range = try ElementNumbers.connectionRange(base: elementNumberBase, generation: handoffGeneration, connection: connectionsMade)
    } catch {
      socket.shut()
      throw error
    }
    connectionsMade += 1
    if range.lowerBound > 1 { params["first_element_number"] = range.lowerBound }
    params["element_number_limit"] = range.upperBound
    do {
      return try send(socket, "hello", params, ticket: nil) as? JSON ?? [:]
    } catch {
      // A helper that refused the session, such as one restarting, keeps the connection open otherwise.
      socket.shut()
      throw error
    }
  }

  private func establish() throws -> SocketConnection {
    guard let descriptor = connectSocket(directories.socketPath) else {
      guard managesHelper else { throw HelperFailure(code: nil, message: "No helper listens on \(directories.socketPath)") }
      return try startHelper()
    }
    let socket = try attach(descriptor)
    let reply = try hello(socket)
    guard managesHelper, let expectedBuild, reply["build"] as? String != expectedBuild else { return socket }
    // The helper runs another build. Only when the installed app is this command's own build is the helper
    // stale and replaced; otherwise this command is the stale one, and it stops nothing that others use.
    guard installedBuild() == expectedBuild else {
      socket.shut()
      onOutdated?()
      throw differsFromInstalled()
    }
    // The socket is never handed out from here, so it is shut also when the lock cannot be taken.
    defer { socket.shut() }
    return try withStartLock {
      // The old helper may already be gone; the restart goes on.
      _ = try? send(socket, "quit", [:], ticket: nil)
      socket.shut()
      waitForSocketToClose()
      return try startHelper(locked: true)
    }
  }

  private func installedBuild() -> String? {
    buildIdentity(ofExecutableAt: installedAppPath + "/Contents/MacOS/" + Product.appExecutableName)
  }

  // Without an installed app nothing can be restarted into, so the message asks for the install.
  private func differsFromInstalled() -> HelperFailure {
    guard installedBuild() != nil else {
      return HelperFailure(code: nil, message: "\(Product.appName) is not installed. Run: \(commandHint()) setup")
    }
    return HelperFailure(code: nil, message: "This \(Product.commandName) command belongs to another build than the installed \(Product.appName). Restart this session, or run: \(commandHint()) setup")
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
    if installedBuild() != expectedBuild, expectedBuild != nil {
      onOutdated?()
      throw differsFromInstalled()
    }
    let launch = { () throws -> SocketConnection in
      if let descriptor = connectSocket(self.directories.socketPath) { return try self.attach(descriptor) }
      // A client closed for good starts no helper: the check and the start happen in one step on the client's queue,
      // so a close either comes first and nothing starts, or returns after `open` started; the wait happens off it.
      try runProcess("/usr/bin/open", ["-g", "-j", installedAppPath, "--args", Product.backgroundArgument], timeout: 15) { start in
        try self.queue.sync {
          if self.closedForGood { throw self.stoppingFailure }
          try start()
        }
      }
      let started = Date()
      while Date().timeIntervalSince(started) < startTimeout {
        if let descriptor = connectSocket(self.directories.socketPath) { return try self.attach(descriptor) }
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
    return try withFileLock(directories.state + "/start-lock", held: "Another start of the helper still holds", action)
  }
}

// Runs `action` holding an exclusive lock on the file at `path`, waiting up to the request timeout for another holder.
// The kernel releases the lock when its holder exits, crashes or execs another command, so a lock is never left
// behind and never taken from a holder that is still running.
// `sleep` waits between tries; tests pass one of their own.
func withFileLock<T>(_ path: String, held: String, waiting timeout: TimeInterval = requestTimeout,
                     sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }, _ action: () throws -> T) throws -> T {
  let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
  guard descriptor >= 0 else { throw HelperFailure(code: nil, message: "Could not open \(path): \(String(cString: strerror(errno)))") }
  defer { Darwin.close(descriptor) }
  // Monotonic, so a change of the clock neither shortens nor stretches the wait.
  let deadline = DispatchTime.now() + timeout
  let late = HelperFailure(code: nil, message: "\(held) \(path)")
  while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
    guard errno == EWOULDBLOCK || errno == EINTR else { throw HelperFailure(code: nil, message: "Could not lock \(path): \(String(cString: strerror(errno)))") }
    let now = DispatchTime.now()
    guard now < deadline else { throw late }
    sleep(min(0.1, Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1e9))
  }
  // A lock taken only after the deadline comes too late for the caller; the close above lets it go.
  guard DispatchTime.now() <= deadline else { throw late }
  return try action()
}
