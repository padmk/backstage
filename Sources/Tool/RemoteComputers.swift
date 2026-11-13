// Calls for another of the user's Macs, named by `computer`. Each goes, without that argument, to the MCP server of
// the app installed on that Mac, over SSH, so that Mac's helper, app list and checks decide it as they would for an
// agent working there. One connection per Mac stays open while this server runs, so element numbers from one call
// keep their meaning in the next.

import Foundation
import HelperLink

let computerArgument = "computer"
let computerRule: JSON = [
  "type": "string", "maxLength": 253,
  "description": "Another of the user's Macs, by the name `ssh` reaches it under (a host or an alias in ~/.ssh/config). The call runs there, under that Mac's own app list; file paths are on that Mac. Omit for this Mac",
]

// Host names and ssh_config aliases, never something ssh could read as an option or a user.
func problemWithComputer(_ name: String) -> String? {
  let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
  guard let first = name.unicodeScalars.first, CharacterSet.alphanumerics.contains(first),
    name.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) })
  else { return "computer must be a host name or an alias from ~/.ssh/config, such as mbp" }
  return nil
}

private let sshPath = "/usr/bin/ssh"
// Covers the SSH login and the first start of the app on that Mac.
private let connectSeconds: TimeInterval = 30
// That Mac's server keeps its own deadlines; this only ends a wait on a connection that stopped answering.
private let callSeconds: TimeInterval = requestTimeout + 30
private let keptErrorBytes = 2000
// A write that ssh does not take in this time, as when that Mac's server stopped reading, ends the connection.
private let writeSeconds: TimeInterval = 10
// Run through sh, whose quoting Fish, zsh and Bash pass on alike, whatever the login shell there is.
private let remoteCommand: String = {
  let commands = Product.appLocations.map { location in
    location.replacingOccurrences(of: NSHomeDirectory(), with: "$HOME") + "/" + Product.commandRelativePath
  }
  return "/bin/sh -c 'for command in \(commands.joined(separator: " ")); do test -x $command && exec $command mcp; done; "
    + "echo \(Product.appName) is not installed there >&2; exit 127'"
}()

// A call for another Mac from the moment it arrives, so a cancellation that comes before its request reaches that
// Mac keeps the request from being sent, and one that comes after follows the request there.
final class RemoteCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var sent: (link: RemoteLink, id: Int)?

  var isCancelled: Bool { lock.withLock { cancelled } }

  func cancel() {
    guard let sent = lock.withLock({ () -> (link: RemoteLink, id: Int)? in
      cancelled = true
      return self.sent
    }) else { return }
    // The reader of the client's input calls this, and must never wait on ssh.
    DispatchQueue.global().async { sent.link.notify("notifications/cancelled", ["requestId": sent.id]) }
  }

  // After the request was written, so the cancellation can never reach that Mac before it.
  fileprivate func requestSent(_ link: RemoteLink, _ id: Int) {
    let late = lock.withLock { () -> Bool in
      sent = (link, id)
      return cancelled
    }
    if late { link.notify("notifications/cancelled", ["requestId": id]) }
  }
}

final class RemoteComputers: @unchecked Sendable {
  private let lock = NSLock()
  // One per Mac, held while its connection opens, so two calls for a new Mac open one and a slow Mac holds up no other.
  private var opening: [String: NSLock] = [:]
  private var links: [String: RemoteLink] = [:]
  // The Macs this session has reached, also before a handoff: a new connection to one of them is a new session there,
  // which numbers its elements anew.
  private var reached: Set<String>

  init(reached: [String]) { self.reached = Set(reached) }

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

  func closeAll() {
    for link in lock.withLock({ Array(links.values) }) { link.close() }
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
    let link = try RemoteLink(computer: computer, clientName: clientName)
    lock.withLock {
      links[computer] = link
      if !reached.insert(computer).inserted { link.owesReopenNote() }
    }
    return link
  }
}

// The SSH connection to one Mac, running its MCP server, with requests matched to replies by id.
final class RemoteLink: @unchecked Sendable {
  let computer: String
  private let process = Process()
  private let input: FileHandle
  private let lock = NSLock()
  // Writes only, apart from `lock`, so a write that waits on ssh holds up no reply and no other state.
  private let writeLock = NSLock()
  private var waiting: [Int: (JSON?) -> Void] = [:]
  private var nextId = 0
  private var ended = false
  private var errors = Data()
  // Set on a connection to a Mac this session reached before, until a reply to the client carries the note.
  private var reopenNoteDue = false

  init(computer: String, clientName: String?) throws {
    self.computer = computer
    let toServer = Pipe()
    let fromServer = Pipe()
    let errorOutput = Pipe()
    // A handoff replaces this process; the connection must not live on in the next one.
    for descriptor in [toServer.fileHandleForWriting.fileDescriptor, fromServer.fileHandleForReading.fileDescriptor, errorOutput.fileHandleForReading.fileDescriptor] {
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }
    process.executableURL = URL(fileURLWithPath: sshPath)
    process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                         "--", computer, remoteCommand]
    process.standardInput = toServer
    process.standardOutput = fromServer
    process.standardError = errorOutput
    input = toServer.fileHandleForWriting
    let flags = fcntl(input.fileDescriptor, F_GETFL)
    _ = fcntl(input.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    process.terminationHandler = { [weak self] _ in self?.end() }
    do {
      try process.run()
    } catch {
      throw unreachable(computer, "ssh did not start: \(error.localizedDescription)")
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
    let opened = try request("initialize", [
      "protocolVersion": "2025-06-18", "capabilities": [:] as JSON,
      "clientInfo": ["name": clientName ?? Product.commandName, "version": Product.version],
    ], seconds: connectSeconds, lostMessage: nil)
    guard opened["result"] is JSON else {
      close()
      throw unreachable(computer, (opened["error"] as? JSON)?["message"] as? String ?? "its server did not start")
    }
    notify("notifications/initialized", nil)
  }

  var isOpen: Bool { lock.withLock { !ended } }

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
    let id: Int? = lock.withLock {
      guard !ended else { return nil }
      nextId += 1
      waiting[nextId] = { reply = $0; done.signal() }
      return nextId
    }
    guard let id else { throw lost(lostMessage) }
    if cancellation?.isCancelled == true {
      lock.withLock { _ = waiting.removeValue(forKey: id) }
      throw HelperFailure(code: "cancelled", message: "The request was cancelled.")
    }
    send(["id": id, "method": method, "params": params])
    cancellation?.requestSent(self, id)
    if done.wait(timeout: .now() + seconds) == .timedOut {
      lock.withLock { _ = waiting.removeValue(forKey: id) }
      throw HelperFailure(code: "timeout", message: "\(computer) did not answer in \(Int(seconds)) s. Read the state there before trying again.")
    }
    guard let reply else { throw lost(lostMessage) }
    return reply
  }

  func notify(_ method: String, _ params: JSON?) {
    var message: JSON = ["method": method]
    if let params { message["params"] = params }
    send(message)
  }

  func close() {
    if process.isRunning { process.terminate() }
    end()
  }

  private func send(_ message: JSON) {
    var full = message
    full["jsonrpc"] = "2.0"
    let data = jsonLine(full)
    guard isOpen else { return }
    let deadline = Date().addingTimeInterval(writeSeconds)
    guard writeLock.lock(before: deadline) else { return close() }
    let written = writeAll(input.fileDescriptor, data, deadline: deadline)
    writeLock.unlock()
    if !written { close() }
  }

  private func receive(_ line: String) {
    guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? JSON,
      let id = (message["id"] as? NSNumber)?.intValue else { return }
    lock.withLock { waiting.removeValue(forKey: id) }?(message)
  }

  // Every request still waiting fails, and later ones open a new connection.
  private func end() {
    let pending: [(JSON?) -> Void] = lock.withLock {
      ended = true
      defer { waiting.removeAll() }
      return Array(waiting.values)
    }
    for finish in pending { finish(nil) }
  }

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

private func unreachable(_ computer: String, _ detail: String) -> HelperFailure {
  let reason = detail.hasSuffix(".") ? String(detail.dropLast()) : detail
  return HelperFailure(code: "computer_unreachable", message: "\(computer) cannot be reached: \(reason). That Mac needs \(Product.appName) installed and an SSH login with a key, without a password prompt, as `ssh \(computer)` takes it.")
}
