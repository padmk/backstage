// Calls for another of the user's Macs, named by `computer`. Each goes, without that argument, to the MCP server of
// the app installed on that Mac, over SSH, so that Mac's helper, app list and checks decide it as they would for an
// agent working there. One connection per Mac stays open while this server runs, so element numbers from one call
// keep their meaning in the next.

import Foundation
import HelperLink
import Synchronization

let computerArgument = "computer"
var computerRule: JSON {
  [
    "type": "string", "maxLength": ComputerName.maxLength,
    "description": "Another of the user's Macs, by the name `ssh` reaches it under (a host or an alias in ~/.ssh/config). The call runs there, under that Mac's own app list; file paths are on that Mac. Omit for this Mac",
  ]
}

// Tests put a stand-in for ssh here, only with a test home.
private let sshPath: String = {
  let environment = ProcessInfo.processInfo.environment
  guard environment["HELPER_TEST_HOME"] != nil, let path = environment["HELPER_TEST_SSH"] else { return "/usr/bin/ssh" }
  return path
}()
// Covers the SSH login and the first start of the app on that Mac.
private let connectSeconds: TimeInterval = 30
// That Mac's server keeps its own deadlines; this only ends a wait on a connection that stopped answering, which is
// then closed. The margin is 30 s, less only when tests shorten the deadline.
private let callSeconds: TimeInterval = requestTimeout + min(30, requestTimeout)
private let keptErrorBytes = 2000
// A write that ssh does not take in this time, as when that Mac's server stopped reading, ends the connection.
private let writeSeconds: TimeInterval = 10
// Run through sh, whose quoting Fish, zsh and Bash pass on alike, whatever the login shell there is.
private let remoteCommand: String = {
  let commands = Product.appLocations.map { location in
    "\"" + location.replacingOccurrences(of: NSHomeDirectory(), with: "$HOME") + "/" + Product.commandRelativePath + "\""
  }
  // Quoted, so a home folder with a space in its path stays one path.
  return "/bin/sh -c 'for command in \(commands.joined(separator: " ")); do test -x \"$command\" && exec \"$command\" mcp; done; "
    + "echo \(Product.appName) is not installed there >&2; exit 127'"
}()

// A call for another Mac from the moment it arrives, so a cancellation that comes before its request reaches that
// Mac keeps the request from being sent, and one that comes after follows the request there.
final class RemoteCancellation: Sendable {
  private struct State {
    var cancelled = false
    var sent: (link: RemoteLink, id: Int)?
  }

  private let state = Mutex(State())

  var isCancelled: Bool { state.withLock { $0.cancelled } }

  func cancel() {
    guard let sent = state.withLock({ state -> (link: RemoteLink, id: Int)? in
      state.cancelled = true
      return state.sent
    }) else { return }
    // The reader of the client's input calls this, and must never wait on ssh; a thread of its own, since work on a
    // busy Dispatch queue can start seconds late.
    Thread.detachNewThread { sent.link.notify("notifications/cancelled", ["requestId": sent.id]) }
  }

  // After the request was written, so the cancellation can never reach that Mac before it.
  fileprivate func requestSent(_ link: RemoteLink, _ id: Int) {
    let late = state.withLock { state -> Bool in
      state.sent = (link, id)
      return state.cancelled
    }
    if late { link.notify("notifications/cancelled", ["requestId": id]) }
  }
}

// Unchecked: every mutable property is read and written holding `lock`; the per-Mac locks in `opening` are held
// only while that Mac's connection opens.
final class RemoteComputers: @unchecked Sendable {
  private let lock = NSLock()
  // One per Mac, held while its connection opens, so two calls for a new Mac open one and a slow Mac holds up no other.
  private var opening: [String: NSLock] = [:]
  private var links: [String: RemoteLink] = [:]
  // The Macs this session has reached, also before a handoff: a new connection to one of them is a new session there,
  // which numbers its elements anew.
  private var reached: Set<String>

  // Connections opened again in this process, for their element number ranges.
  private var reopened = 0
  private let generation: Int
  // Set by `closeForGood`, as when the command stops: no connection opens after it.
  private var closed = false
  // Connections whose ssh runs and whose handshake has not finished, so `closeForGood` ends them too.
  private var openingLinks: [ObjectIdentifier: RemoteLink] = [:]
  private let ssh: String

  // `ssh` is the program run in place of ssh; tests pass a stand-in.
  init(reached: [String], generation: Int, ssh: String = sshPath) {
    self.reached = Set(reached)
    self.generation = generation
    self.ssh = ssh
  }

  var reachedComputers: [String] { lock.withLock { reached.sorted() } }

  // The result of the call as that Mac's server gave it, ready for the client.
  func call(_ computer: String, _ name: String, _ arguments: JSON, clientName: String?, cancellation: RemoteCancellation) throws -> JSON {
    let link = try self.link(computer, clientName: clientName)
    let reopenNote = "[The connection to \(computer) was opened again, so element numbers read there before no longer apply. Read the window state again.]"
    let reply: JSON
    do {
      reply = try link.request("tools/call", ["name": name, "arguments": arguments], seconds: callSeconds, cancellation: cancellation,
                               lostMessage: "The connection to \(computer) ended during the call, so it may have run. Read the state there before trying again.")
      if let error = reply["error"] as? JSON {
        throw HelperFailure(code: nil, message: "\(computer): \(error["message"] as? String ?? "the call failed")")
      }
    } catch let failure as HelperFailure {
      guard link.takeReopenNote() else { throw failure }
      throw HelperFailure(code: failure.code, message: "\(failure.message) \(reopenNote)")
    }
    var result = reply["result"] as? JSON ?? [:]
    if link.takeReopenNote() {
      result["content"] = [["type": "text", "text": reopenNote] as JSON] + (result["content"] as? [Any] ?? [])
    }
    return result
  }

  // Closes the connections; the next call opens a new one, as after a handoff that did not happen.
  func closeAll() {
    for link in lock.withLock({ Array(links.values) }) { link.close() }
  }

  // Closes the connections for good: a call already on its way gets `stopping` rather than a new connection.
  func closeForGood() {
    let all = lock.withLock { () -> [RemoteLink] in
      closed = true
      return Array(links.values) + Array(openingLinks.values)
    }
    for link in all { link.close() }
  }

  private func link(_ computer: String, clientName: String?) throws -> RemoteLink {
    if let link = lock.withLock({ links[computer] }), link.isOpen { return link }
    let opening = lock.withLock { () -> NSLock in
      if let existing = self.opening[computer] { return existing }
      let created = NSLock()
      self.opening[computer] = created
      return created
    }
    opening.lock()
    defer { opening.unlock() }
    if let link = lock.withLock({ links[computer] }), link.isOpen { return link }
    // A Mac this session reached before numbers elements from a range no earlier connection there used, so a number
    // read before does not name another element; a Backstage there too old for this numbers anew, as the note says.
    let base = try lock.withLock { () throws -> Int in
      guard reached.contains(computer) else { return 0 }
      reopened += 1
      return try ElementNumbers.remoteBase(generation: generation, reopened: reopened)
    }
    // Started and registered in one step with the check, so a session closed for good starts no ssh, and one closed
    // later ends the connection, whose handshake then fails before it writes more.
    var registered: ObjectIdentifier?
    defer { if let registered { lock.withLock { _ = openingLinks.removeValue(forKey: registered) } } }
    let link: RemoteLink
    do {
      link = try RemoteLink(computer: computer, clientName: clientName, elementNumberBase: base, ssh: ssh, start: { started, run in
        try lock.withLock {
          if closed { throw stoppingFailure }
          try run()
          registered = ObjectIdentifier(started)
          openingLinks[ObjectIdentifier(started)] = started
        }
      })
    } catch {
      // A handshake that failed because the session was closed for good sent no call.
      if lock.withLock({ closed }) { throw stoppingFailure }
      throw error
    }
    let published = lock.withLock { () -> Bool in
      // A close while this connection opened ends it before any call goes over it.
      guard !closed else { return false }
      links[computer] = link
      if !reached.insert(computer).inserted { link.owesReopenNote() }
      return true
    }
    guard published else {
      link.close()
      throw stoppingFailure
    }
    return link
  }
}

// The requests waiting on one link and whether it has ended, changed together under one lock: once it has ended, by a
// timeout or by its connection, no request registers on it and every one that waited has been failed.
// Unchecked: every mutable property is read and written holding `lock`.
final class LinkCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var waiting: [Int: (JSON?) -> Void] = [:]
  private var nextId = 0
  private var ended = false
  // Called each time a write finds the pipe full; tests wait on it.
  private let onFullPipe: (@Sendable () -> Void)?

  init(onFullPipe: (@Sendable () -> Void)? = nil) { self.onFullPipe = onFullPipe }

  var isOpen: Bool { lock.withLock { !ended } }

  // The id for a request, or nil once the link has ended.
  func register(_ finish: @escaping (JSON?) -> Void) -> Int? {
    lock.withLock {
      guard !ended else { return nil }
      nextId += 1
      waiting[nextId] = finish
      return nextId
    }
  }

  func remove(_ id: Int) { lock.withLock { _ = waiting.removeValue(forKey: id) } }

  // The request a reply answers, taken so only one answer counts.
  func take(_ id: Int) -> ((JSON?) -> Void)? { lock.withLock { waiting.removeValue(forKey: id) } }

  // Writes `data` to `descriptor`, nonblocking, before `deadline`. Each chunk is written holding the lock, after the
  // checks that the link has not ended and the deadline has not passed, and the wait for room happens outside it, so
  // nothing is written once the link has ended or its time is up, also by a write that began before. False when not
  // all of it was written.
  func write(_ descriptor: Int32, _ data: Data, deadline: Date) -> Bool {
    enum Attempt {
      case wrote(Int)
      case full
      case stopped
    }
    return data.withUnsafeBytes { buffer in
      guard var base = buffer.baseAddress else { return true }
      var left = buffer.count
      while left > 0 {
        let attempt: Attempt = lock.withLock {
          guard !ended, Date() < deadline else { return .stopped }
          let written = Darwin.write(descriptor, base, left)
          if written >= 0 { return .wrote(written) }
          if errno == EINTR { return .wrote(0) }
          return errno == EAGAIN || errno == EWOULDBLOCK ? .full : .stopped
        }
        switch attempt {
        case .stopped:
          return false
        case .wrote(let count):
          left -= count
          base = base.advanced(by: count)
        case .full:
          onFullPipe?()
          let remaining = deadline.timeIntervalSinceNow
          guard remaining > 0 else { return false }
          var ready = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
          let polled = poll(&ready, 1, Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up)))
          // No room by the deadline, or a poll that failed: the write ends here. An error on the descriptor itself
          // shows in the next write.
          if polled == 0 || (polled < 0 && errno != EINTR) { return false }
        }
      }
      return true
    }
  }

  // Ends the link and fails every request waiting, except `id`, which reports its own failure.
  func end() {
    let pending: [(JSON?) -> Void] = lock.withLock {
      ended = true
      defer { waiting.removeAll() }
      return Array(waiting.values)
    }
    for finish in pending { finish(nil) }
  }

  // Claims the timeout of request `id` and ends the link, failing every other request waiting, in one step. False
  // when the request no longer waits: a reply or the end of the link took it first, and its callback reports that.
  func claimTimeout(_ id: Int) -> Bool {
    let pending: [(JSON?) -> Void]? = lock.withLock {
      guard waiting.removeValue(forKey: id) != nil else { return nil }
      ended = true
      defer { waiting.removeAll() }
      return Array(waiting.values)
    }
    guard let pending else { return false }
    for finish in pending { finish(nil) }
    return true
  }
}

// The SSH connection to one Mac, running its MCP server, with requests matched to replies by id.
// Unchecked: the error output and the note are read and written holding `lock`, the requests waiting are in `calls`,
// writes to ssh hold `writeLock`, and the other properties are constants.
final class RemoteLink: @unchecked Sendable {
  let computer: String
  private let process = Process()
  private let input: FileHandle
  private let lock = NSLock()
  // Writes only, apart from `lock`, so a write that waits on ssh holds up no reply and no other state.
  private let writeLock = NSLock()
  private let calls: LinkCalls
  private var errors = Data()
  // Set on a connection to a Mac this session reached before, until a reply to the client carries the note.
  private var reopenNoteDue = false

  // `ssh` is the program run in place of ssh; tests pass a stand-in, and may watch for a write that finds the pipe full.
  // `start` runs ssh, given the link and the function that starts it, so a caller can decide in one step whether it
  // starts and record it; a throw there leaves ssh unstarted, and nothing is written.
  init(computer: String, clientName: String?, elementNumberBase: Int, ssh: String = sshPath, onFullPipe: (@Sendable () -> Void)? = nil,
       start: (RemoteLink, () throws -> Void) throws -> Void = { try $1() }) throws {
    self.computer = computer
    calls = LinkCalls(onFullPipe: onFullPipe)
    let toServer = Pipe()
    let fromServer = Pipe()
    let errorOutput = Pipe()
    // A handoff replaces this process; the connection must not live on in the next one.
    for descriptor in [toServer.fileHandleForWriting.fileDescriptor, fromServer.fileHandleForReading.fileDescriptor, errorOutput.fileHandleForReading.fileDescriptor] {
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }
    process.executableURL = URL(fileURLWithPath: ssh)
    process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                         "--", computer, remoteCommand]
    process.standardInput = toServer
    process.standardOutput = fromServer
    process.standardError = errorOutput
    input = toServer.fileHandleForWriting
    let flags = fcntl(input.fileDescriptor, F_GETFL)
    _ = fcntl(input.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    process.terminationHandler = { [weak self] _ in self?.end() }
    try start(self) {
      do {
        try process.run()
      } catch {
        throw unreachable(computer, "ssh did not start: \(error.localizedDescription)")
      }
    }
    let output = fromServer.fileHandleForReading
    Thread { [weak self] in
      var framer = LineFramer()
      while true {
        let chunk = output.availableData
        guard !chunk.isEmpty, let self else { break }
        for line in framer.lines(in: chunk) { self.receive(line) }
      }
      self?.end()
    }.start()
    let errorHandle = errorOutput.fileHandleForReading
    Thread { [weak self] in
      while true {
        let chunk = errorHandle.availableData
        guard !chunk.isEmpty, let self else { break }
        self.lock.withLock {
          self.errors.append(chunk)
          if self.errors.count > keptErrorBytes { self.errors = self.errors.suffix(keptErrorBytes) }
        }
      }
    }.start()
    // A connection that never opens leaves no ssh behind.
    let opened: JSON
    do {
      var params: JSON = ["protocolVersion": "2025-06-18", "capabilities": [:] as JSON,
        "clientInfo": ["name": clientName ?? Product.commandName, "version": Product.version]]
      if elementNumberBase > 0 { params["_meta"] = [Product.elementNumberBaseKey: elementNumberBase] }
      opened = try request("initialize", params, seconds: connectSeconds, lostMessage: nil)
    } catch {
      close()
      throw error
    }
    guard opened["result"] is JSON else {
      close()
      throw unreachable(computer, (opened["error"] as? JSON)?["message"] as? String ?? "its server did not start")
    }
    notify("notifications/initialized", nil)
  }

  var isOpen: Bool { calls.isOpen }

  func owesReopenNote() { lock.withLock { reopenNoteDue = true } }

  // Whether this reply is the one to carry the note.
  func takeReopenNote() -> Bool {
    lock.withLock {
      defer { reopenNoteDue = false }
      return reopenNoteDue
    }
  }

  // The reply, with `result` or `error`. `lostMessage` is the failure when the connection ends during the request;
  // without one, the failure says why it ended, as when it opens.
  func request(_ method: String, _ params: JSON, seconds: TimeInterval, cancellation: RemoteCancellation? = nil, lostMessage: String?) throws -> JSON {
    let done = DispatchSemaphore(value: 0)
    var reply: JSON?
    guard let id = calls.register({ reply = $0; done.signal() }) else { throw lost(lostMessage) }
    if cancellation?.isCancelled == true {
      calls.remove(id)
      throw HelperFailure(code: "cancelled", message: "The request was cancelled.")
    }
    send(["id": id, "method": method, "params": params])
    cancellation?.requestSent(self, id)
    if done.wait(timeout: .now() + seconds) == .timedOut {
      // A connection that missed the other Mac's own deadline is not used again: it ends in the same step that claims
      // the timeout, so no later request registers on it, and closing it ends that session there.
      if calls.claimTimeout(id) {
        close()
        throw HelperFailure(code: "timeout", message: "\(computer) did not answer in \(Int(seconds)) s. Read the state there before trying again.")
      }
      // A reply or the end of the link took the request just as its time ran out; its callback is about to report it.
      guard done.wait(timeout: .now() + 2) == .success else { throw lost(lostMessage) }
    }
    guard let reply else { throw lost(lostMessage) }
    return reply
  }

  func notify(_ method: String, _ params: JSON?) {
    var message: JSON = ["method": method]
    if let params { message["params"] = params }
    send(message)
  }

  // Ended first, so no request registers or writes while ssh stops.
  func close() {
    end()
    if process.isRunning { process.terminate() }
  }

  private func send(_ message: JSON) {
    var full = message
    full["jsonrpc"] = "2.0"
    let data = jsonLine(full)
    guard isOpen else { return }
    let deadline = Date().addingTimeInterval(writeSeconds)
    guard writeLock.lock(before: deadline) else { return close() }
    // Checks the end before each chunk, so a link that ended meanwhile gets nothing more.
    let written = calls.write(input.fileDescriptor, data, deadline: deadline)
    writeLock.unlock()
    if !written { close() }
  }

  private func receive(_ line: String) {
    // Lines that are no reply, such as a login banner, are skipped.
    guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? JSON,
      let id = (message["id"] as? NSNumber)?.intValue else { return }
    calls.take(id)?(message)
  }

  // Every request still waiting fails, and later ones open a new connection.
  private func end() { calls.end() }

  private func lost(_ message: String?) -> HelperFailure {
    if let message { return HelperFailure(code: "outcome_unknown", message: message) }
    // ssh may still be writing why it stopped.
    let deadline = Date().addingTimeInterval(2)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    Thread.sleep(forTimeInterval: 0.1)
    let detail = lock.withLock { String(decoding: errors, as: UTF8.self) }.trimmingCharacters(in: .whitespacesAndNewlines)
    return unreachable(computer, detail.isEmpty ? "the connection ended" : detail)
  }
}

private let stoppingFailure = HelperFailure(code: "stopping", message: "This command is stopping, so the call was not sent.")

private func unreachable(_ computer: String, _ detail: String) -> HelperFailure {
  let reason = detail.hasSuffix(".") ? String(detail.dropLast()) : detail
  return HelperFailure(code: "computer_unreachable", message: "\(computer) cannot be reached: \(reason). That Mac needs \(Product.appName) installed and an SSH login with a key, without a password prompt, as `ssh \(computer)` takes it.")
}
