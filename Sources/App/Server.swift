// The Unix socket server: one reader and one worker queue per connection, so a request can be cancelled
// while another is running, and a closed connection closes its approval window.

import AppKit

private let idleExitSeconds: TimeInterval = 120
// Long enough for a client to reconnect and keep what the user decided.
private let detachedSessionSeconds: TimeInterval = 600

final class Connections {
  private let lock = NSLock()
  private var count = 0
  private var lastClosed = Date()

  func opened() { lock.withLock { count += 1 } }

  func closed() {
    lock.withLock {
      count -= 1
      lastClosed = Date()
    }
  }

  var shouldExit: Bool {
    lock.withLock { count == 0 && Date().timeIntervalSince(lastClosed) > idleExitSeconds }
  }
}

let connections = Connections()

// A session id outlives a connection, so a reconnecting server keeps its approvals.
private var sessions: [String: ApprovalSession] = [:]
private let sessionsLock = NSLock()

// The agents with a connection open now, by the names their clients give.
func connectedClients() -> [String] {
  let attached = sessionsLock.withLock { sessions.values.filter { $0.attachedConnections > 0 } }
  let names = attached.map { session in session.lock.withLock { session.clientName } }.map { readableClientName($0) ?? "An agent" }
  return Array(Set(names)).sorted()
}

// Each approved app, with the signer the user approved, or nil for a process without a valid signature.
func sessionApprovals() -> [(bundleId: String, signer: String?)] {
  let all = sessionsLock.withLock { Array(sessions.values) }
  let keys = Set(all.flatMap { session in session.lock.withLock { Array(session.approved) } })
  var found: [String: String?] = [:]
  for key in keys {
    let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { continue }
    found[parts[0]] = parts[1].hasPrefix("pid:") ? String?.none : parts[1]
  }
  return found.map { (bundleId: $0.key, signer: $0.value) }
}

// Returns whether any session held an approval for the app.
@discardableResult
func revokeSessionApprovals(bundleId: String) -> Bool {
  let all = sessionsLock.withLock { Array(sessions.values) }
  var found = false
  for session in all {
    session.lock.withLock {
      let matching = session.approved.filter { $0.hasPrefix(bundleId + "|") }
      if !matching.isEmpty { found = true }
      session.approved.subtract(matching)
    }
  }
  return found
}

private func attachSession(id: String) -> ApprovalSession {
  sessionsLock.withLock {
    let session = sessions[id] ?? ApprovalSession()
    sessions[id] = session
    session.attachedConnections += 1
    return session
  }
}

private func detach(_ session: ApprovalSession) {
  sessionsLock.withLock {
    session.attachedConnections -= 1
    session.detachedAt = Date()
  }
}

private func forgetDetachedSessions() {
  sessionsLock.withLock {
    sessions = sessions.filter {
      $0.value.attachedConnections > 0 || Date().timeIntervalSince($0.value.detachedAt) < detachedSessionSeconds
    }
  }
}

final class Connection {
  let descriptor: Int32
  private let lock = NSLock()
  private var generation = 0
  private var isClosed = false
  private var cancelHandlers: [UUID: () -> Void] = [:]
  private var currentSession = ApprovalSession()
  private var adoptedSession: ApprovalSession?
  private var requestGeneration = 0

  var session: ApprovalSession { lock.withLock { currentSession } }

  init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  func adopt(sessionId: String) {
    let adopted = attachSession(id: sessionId)
    let previous = lock.withLock { () -> ApprovalSession? in
      defer {
        currentSession = adopted
        adoptedSession = adopted
      }
      return adoptedSession
    }
    if let previous { detach(previous) }
  }

  var isCancelled: Bool {
    lock.withLock { isClosed || requestGeneration != generation }
  }

  func throwIfCancelled() throws {
    if isCancelled {
      throw HelperError(code: "cancelled", message: "The request was cancelled.")
    }
  }

  func begin(generation captured: Int) {
    lock.withLock { requestGeneration = captured }
  }

  var currentGeneration: Int { lock.withLock { generation } }

  func onCancel(_ handler: @escaping () -> Void) -> () -> Void {
    let id = UUID()
    let cancelledAlready = lock.withLock { () -> Bool in
      if isClosed || requestGeneration != generation { return true }
      cancelHandlers[id] = handler
      return false
    }
    if cancelledAlready { handler() }
    return { [weak self] in
      self?.lock.withLock { _ = self?.cancelHandlers.removeValue(forKey: id) }
    }
  }

  private func fireCancelHandlers() {
    let handlers = lock.withLock { () -> [() -> Void] in
      let all = Array(cancelHandlers.values)
      cancelHandlers.removeAll()
      return all
    }
    handlers.forEach { $0() }
  }

  func cancelRequests() {
    lock.withLock { generation += 1 }
    fireCancelHandlers()
  }

  func close() {
    let adopted = lock.withLock { () -> ApprovalSession? in
      isClosed = true
      defer { adoptedSession = nil }
      return adoptedSession
    }
    if let adopted { detach(adopted) }
    fireCancelHandlers()
  }
}

private func write(_ reply: JSON, to descriptor: Int32) {
  guard var data = try? JSONSerialization.data(withJSONObject: reply) else { return }
  data.append(0x0a)
  data.withUnsafeBytes { buffer in
    var offset = 0
    while offset < buffer.count {
      let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
      if written <= 0 { return }
      offset += written
    }
  }
}

private func perform(_ request: JSON, generation: Int, connection: Connection) {
  let id = request["id"] ?? NSNull()
  connection.begin(generation: generation)
  do {
    try connection.throwIfCancelled()
    if let deadline = request["deadline"] as? Double, Date().timeIntervalSince1970 * 1000 > deadline {
      throw HelperError(code: "expired", message: "The request waited too long and was not run.")
    }
    let params = request["params"] as? JSON ?? [:]
    let method = request["method"] as? String ?? ""
    if method == "hello", let sessionId = params["session_id"] as? String { connection.adopt(sessionId: sessionId) }
    let result = try handle(method: method, params: params, connection: connection)
    write(["id": id, "result": result], to: connection.descriptor)
  } catch let error as HelperError {
    write(["id": id, "error": ["code": error.code, "message": error.message]], to: connection.descriptor)
  } catch {
    write(["id": id, "error": ["code": "failed", "message": error.localizedDescription]], to: connection.descriptor)
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
    while let newline = pending.firstIndex(of: 0x0a) {
      let line = Data(pending[pending.startIndex..<newline])
      pending = Data(pending[(newline + 1)...])
      guard let request = try? JSONSerialization.jsonObject(with: line) as? JSON else {
        write(["id": NSNull(), "error": ["code": "invalid_request", "message": "Not a JSON object."]], to: descriptor)
        continue
      }
      // Handled here rather than queued, because the worker may be busy with what is being cancelled.
      if request["method"] as? String == "cancel" {
        connection.cancelRequests()
        continue
      }
      let generation = connection.currentGeneration
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
      connections.opened()
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
