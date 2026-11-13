// The Unix socket server: one reader and one worker queue per connection, so a request can be cancelled
// while another is running, and a closed connection ends its requests.

import AppKit
import HelperLink
import Synchronization

private let idleExitSeconds: TimeInterval = 120
// Bounds that keep one client from exhausting the helper: a frame no request needs (type_text takes 100,000
// characters), requests waiting on one connection, connections at once, and sessions kept for reconnecting.
private let maxQueuedRequests = 64
private let maxConnections = 64
private let maxSessions = 256
// Long enough for a client to reconnect and keep what the user decided.
private let detachedSessionSeconds: TimeInterval = 600

final class Connections: Sendable {
  private struct State {
    var count = 0
    var lastClosed = Date()
  }

  private let state = Mutex(State())

  // Takes a place for a new connection, or refuses one beyond the limit.
  func open() -> Bool {
    state.withLock { state in
      guard state.count < maxConnections else { return false }
      state.count += 1
      return true
    }
  }

  func closed() {
    state.withLock { state in
      state.count -= 1
      state.lastClosed = Date()
    }
  }

  var shouldExit: Bool {
    state.withLock { $0.count == 0 && Date().timeIntervalSince($0.lastClosed) > idleExitSeconds }
  }
}

let connections = Connections()

// A session id outlives a connection, so a reconnecting server keeps its approvals. Held also while a session's
// count of connections changes.
private let sessions = Mutex<[String: ApprovalSession]>([:])

// The agents with a connection open now, by the names their clients give.
func connectedClients() -> [String] {
  let attached = sessions.withLock { $0.values.filter { $0.attachedConnections > 0 } }
  let names = attached.map { session in session.lock.withLock { session.clientName } }.map { readableClientName($0) ?? "An agent" }
  return Array(Set(names)).sorted()
}

private func attachSession(id: String) -> ApprovalSession {
  sessions.withLock { sessions in
    // Past the limit, the sessions detached longest go first; attached ones stay.
    if sessions[id] == nil, sessions.count >= maxSessions {
      let detached = sessions.filter { $0.value.attachedConnections == 0 }.sorted { $0.value.detachedAt < $1.value.detachedAt }
      for (key, _) in detached.prefix(sessions.count - maxSessions + 1) { sessions.removeValue(forKey: key) }
    }
    let session = sessions[id] ?? ApprovalSession()
    sessions[id] = session
    session.attachedConnections += 1
    return session
  }
}

private func detach(_ session: ApprovalSession) {
  sessions.withLock { _ in
    session.attachedConnections -= 1
    session.detachedAt = Date()
  }
}

private func forgetDetachedSessions() {
  sessions.withLock { sessions in
    sessions = sessions.filter {
      $0.value.attachedConnections > 0 || Date().timeIntervalSince($0.value.detachedAt) < detachedSessionSeconds
    }
  }
}

final class Connection: Sendable {
  let descriptor: Int32
  // The reader and the worker both answer on this socket, so one reply is written whole before the next starts.
  let writeLock = NSLock()

  private struct State {
    var generation = 0
    var isClosed = false
    var cancelHandlers: [UUID: @Sendable () -> Void] = [:]
    // Requests from the moment they are queued until they finish, those of them cancelled, and the one running now.
    var outstandingIds = Set<String>()
    var cancelledIds = Set<String>()
    var runningId: String?
    var runningDeadline: Date?
    var queued = 0
    var currentSession: ApprovalSession
    var adoptedSession: ApprovalSession?
    var requestGeneration = 0

    // The connection closed, a cancel of all its requests came after the running one began, or the running one
    // was cancelled by its id.
    var isCancelled: Bool { isClosed || requestGeneration != generation || runningId.map(cancelledIds.contains) == true }

    mutating func takeCancelHandlers() -> [@Sendable () -> Void] {
      defer { cancelHandlers.removeAll() }
      return Array(cancelHandlers.values)
    }
  }

  private let state: Mutex<State>

  var session: ApprovalSession { state.withLock { $0.currentSession } }

  // Registered from the start, so approvals given to a client that never says hello are listed and revocable too.
  init(descriptor: Int32) {
    self.descriptor = descriptor
    let own = attachSession(id: "connection-\(UUID().uuidString)")
    state = Mutex(State(currentSession: own, adoptedSession: own))
  }

  func adopt(sessionId: String) {
    let adopted = attachSession(id: sessionId)
    let previous = state.withLock { state -> ApprovalSession? in
      defer {
        state.currentSession = adopted
        state.adoptedSession = adopted
      }
      return state.adoptedSession
    }
    if let previous { detach(previous) }
  }

  var isCancelled: Bool { state.withLock { $0.isCancelled } }

  func throwIfCancelled() throws {
    if isCancelled {
      throw HelperError(code: "cancelled", message: "The request was cancelled.")
    }
  }

  func begin(generation captured: Int, id: String?, deadline: Date?) {
    state.withLock { state in
      state.requestGeneration = captured
      state.runningId = id
      state.runningDeadline = deadline
    }
  }

  // When the client gives up on the running request, if it said.
  var deadline: Date? { state.withLock { $0.runningDeadline } }

  // Takes a place in this connection's queue, or refuses one beyond the limit.
  func enqueue(id: String?) -> Bool {
    state.withLock { state in
      guard state.queued < maxQueuedRequests else { return false }
      state.queued += 1
      if let id { state.outstandingIds.insert(id) }
      return true
    }
  }

  func finish(id: String?) {
    state.withLock { state in
      state.queued -= 1
      if let id {
        state.cancelledIds.remove(id)
        state.outstandingIds.remove(id)
      }
      state.runningId = nil
      state.runningDeadline = nil
    }
  }

  var currentGeneration: Int { state.withLock { $0.generation } }

  // Runs the handler when the running request is cancelled, at once when it already is. The returned function
  // removes it.
  func onCancel(_ handler: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
    let id = UUID()
    let cancelledAlready = state.withLock { state -> Bool in
      if state.isCancelled { return true }
      state.cancelHandlers[id] = handler
      return false
    }
    if cancelledAlready { handler() }
    return { [weak self] in
      self?.state.withLock { _ = $0.cancelHandlers.removeValue(forKey: id) }
    }
  }

  func cancelRequests() {
    let handlers = state.withLock { state in
      state.generation += 1
      return state.takeCancelHandlers()
    }
    handlers.forEach { $0() }
  }

  // One request: if it runs now, its waits end; if it is queued, it will not run. A request
  // that has already finished is not marked, so its id cannot cancel a later one. Requests run one at a time, so
  // the handlers registered belong to the running one, and they are taken in the same step as that check.
  func cancel(requestId: String) {
    let handlers = state.withLock { state -> [@Sendable () -> Void] in
      guard state.outstandingIds.contains(requestId) else { return [] }
      state.cancelledIds.insert(requestId)
      guard state.runningId == requestId else { return [] }
      return state.takeCancelHandlers()
    }
    handlers.forEach { $0() }
  }

  func close() {
    let (adopted, handlers) = state.withLock { state in
      state.isClosed = true
      defer { state.adoptedSession = nil }
      return (state.adoptedSession, state.takeCancelHandlers())
    }
    if let adopted { detach(adopted) }
    handlers.forEach { $0() }
  }
}

// One reply as one line. A reply that is not valid JSON, such as one with a number that is not finite, would raise in
// JSONSerialization and end the app; the client gets an error for that request instead.
func encodedReply(_ reply: JSON) -> Data {
  var data: Data
  do {
    guard JSONSerialization.isValidJSONObject(reply) else { throw HelperError(code: "outcome_unknown", message: "The reply is not valid JSON.") }
    data = try JSONSerialization.data(withJSONObject: reply)
  } catch {
    appLog.error("A reply could not be encoded: \(String(describing: error), privacy: .public)")
    // The id came parsed from the request, so it encodes.
    let fallback: JSON = ["id": reply["id"] ?? NSNull(),
                          "error": ["code": "outcome_unknown", "message": "The reply could not be encoded, so the request may or may not have worked. Read the state before trying again."]]
    data = jsonLine(fallback)
    data.removeLast()
  }
  data.append(0x0a)
  return data
}

private func write(_ reply: JSON, to connection: Connection) {
  let data = encodedReply(reply)
  let descriptor = connection.descriptor
  connection.writeLock.lock()
  defer { connection.writeLock.unlock() }
  data.withUnsafeBytes { buffer in
    var offset = 0
    while offset < buffer.count {
      let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
      if written <= 0 { return }
      offset += written
    }
  }
}

// How many requests run now, so a restart for a new grant waits until none does. None starts once the restart is
// planned, so requests that keep coming cannot hold it off.
enum RequestActivity {
  private struct State {
    var running = 0
    var restartPlanned = false
  }

  private static let state = Mutex(State())

  // False once the app is about to restart: the request is not run.
  static func started() -> Bool {
    state.withLock { state in
      if state.restartPlanned { return false }
      state.running += 1
      return true
    }
  }

  static func ended() { state.withLock { $0.running -= 1 } }

  // True for the first caller only, so one restart waits however often it is asked for.
  static func planRestart() -> Bool {
    state.withLock { state in
      defer { state.restartPlanned = true }
      return !state.restartPlanned
    }
  }

  static var isIdle: Bool { state.withLock { $0.running == 0 } }
}

let expiredError = HelperError(code: "expired", message: "The request waited too long and was not run.")

private let connectionKey = "connection"

// The connection whose request runs on this thread, so deep waits such as a script child can end when the
// request is cancelled without every caller passing it down.
func currentConnection() -> Connection? { Thread.current.threadDictionary[connectionKey] as? Connection }

private func perform(_ request: JSON, generation: Int, connection: Connection) {
  let id = request["id"] ?? NSNull()
  let key = request["id"].map { "\($0)" }
  // Milliseconds since 1970.
  let deadline = (request["deadline"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
  connection.begin(generation: generation, id: key, deadline: deadline)
  Thread.current.threadDictionary[connectionKey] = connection
  let admitted = RequestActivity.started()
  defer {
    if admitted { RequestActivity.ended() }
    Thread.current.threadDictionary.removeObject(forKey: connectionKey)
    connection.finish(id: key)
  }
  do {
    guard admitted else {
      throw HelperError(code: "restarting", message: "Backstage is restarting to pick up a permission the user just allowed. Try again in a few seconds.")
    }
    try connection.throwIfCancelled()
    if let deadline, Date() > deadline { throw expiredError }
    let params = request["params"] as? JSON ?? [:]
    let method = request["method"] as? String ?? ""
    if method == "hello", let sessionId = params["session_id"] as? String { connection.adopt(sessionId: sessionId) }
    let result = try handle(method: method, params: params, connection: connection)
    write(["id": id, "result": result], to: connection)
  } catch let error as HelperError {
    write(["id": id, "error": ["code": error.code, "message": error.message]], to: connection)
  } catch {
    write(["id": id, "error": ["code": "failed", "message": error.localizedDescription]], to: connection)
  }
}

private func serve(_ descriptor: Int32) {
  let connection = Connection(descriptor: descriptor)
  let worker = DispatchQueue(label: "connection-\(descriptor)")
  var pending = Data()
  var chunk = [UInt8](repeating: 0, count: 65536)
  while true {
    let count = read(descriptor, &chunk, chunk.count)
    if count <= 0 { break }
    pending.append(contentsOf: chunk[0..<count])
    if pending.count > maxFrameBytes, pending.firstIndex(of: 0x0a) == nil {
      write(["id": NSNull(), "error": ["code": "request_too_large", "message": "A request is larger than \(maxFrameBytes >> 20) MB, so the connection is closed."]], to: connection)
      break
    }
    while let newline = pending.firstIndex(of: 0x0a) {
      let line = Data(pending[pending.startIndex..<newline])
      pending = Data(pending[(newline + 1)...])
      guard line.count <= maxFrameBytes else {
        write(["id": NSNull(), "error": ["code": "request_too_large", "message": "A request is larger than \(maxFrameBytes >> 20) MB."]], to: connection)
        continue
      }
      guard let request = try? JSONSerialization.jsonObject(with: line) as? JSON else {
        write(["id": NSNull(), "error": ["code": "invalid_request", "message": "Not a JSON object."]], to: connection)
        continue
      }
      // Handled here rather than queued, because the worker may be busy with what is being cancelled.
      if request["method"] as? String == "cancel" {
        if let target = (request["params"] as? JSON)?["id"] {
          connection.cancel(requestId: "\(target)")
        } else {
          connection.cancelRequests()
        }
        continue
      }
      let generation = connection.currentGeneration
      guard connection.enqueue(id: request["id"].map { "\($0)" }) else {
        write(["id": request["id"] ?? NSNull(), "error": ["code": "busy", "message": "Too many requests are waiting on this connection. Wait for answers before sending more."]], to: connection)
        continue
      }
      worker.async { perform(request, generation: generation, connection: connection) }
    }
  }
  connection.close()
  // The descriptor closes after the worker finishes, so it cannot be reused while a reply is written.
  worker.async {
    close(descriptor)
    connections.closed()
  }
}

// The socket appears at `path` only once it accepts connections: it is bound and listening under a name of its own,
// then renamed into place, so a client that sees the file can connect.
private func listen(at path: String) -> Int32? {
  let directory = (path as NSString).deletingLastPathComponent
  try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  func address(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: Array(path.utf8) + [0])
    }
    return address
  }
  let size = socklen_t(MemoryLayout<sockaddr_un>.size)
  let staging = path + ".\(getpid())"
  guard var final = address(path), var staged = address(staging) else { return nil }
  // A socket nobody answers on was left by an earlier helper; a live one means this copy is not needed.
  let probe = socket(AF_UNIX, SOCK_STREAM, 0)
  let isLive = withUnsafePointer(to: &final) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, size) }
  }
  close(probe)
  if isLive == 0 { return nil }
  let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else { return nil }
  unlink(staging)
  let bound = withUnsafePointer(to: &staged) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, size) }
  }
  guard bound == 0, chmod(staging, 0o600) == 0, Darwin.listen(descriptor, 16) == 0, rename(staging, path) == 0 else {
    unlink(staging)
    close(descriptor)
    return nil
  }
  return descriptor
}

func startServer() {
  // A client that leaves during a reply must not end the helper for the other sessions.
  signal(SIGPIPE, SIG_IGN)
  guard let server = listen(at: Configuration.socketPath) else { exit(0) }

  Thread.detachNewThread {
    while true {
      let client = accept(server, nil, nil)
      if client < 0 {
        sleep(seconds: 0.05)
        continue
      }
      var enabled: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
      guard connections.open() else {
        close(client)
        continue
      }
      Thread.detachNewThread { serve(client) }
    }
  }

  Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
    forgetDetachedSessions()
    if connections.shouldExit, !isControlWindowOpen, !Preferences.keepsRunning {
      unlink(Configuration.socketPath)
      exit(0)
    }
  }
}
