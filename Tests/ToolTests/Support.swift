// Runs the real command and app builds, against either a fake helper or the app built for tests. Every path these
// tests write to is inside a temporary directory.

import Darwin
import Foundation
import HelperLink
import Testing

typealias Object = [String: Any]

// The package's built products: the test bundle lies next to them.
private final class TestBundleMarker {}
let productsDirectory: URL = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent()

let commandBinary = productsDirectory.appendingPathComponent("backstage-tool").path
let appBinary = productsDirectory.appendingPathComponent("Backstage").path

// Short, because a Unix socket path has a small limit.
final class TemporaryHome {
  let path: String

  init() {
    var template = Array("/tmp/bk-XXXXXX".utf8CString)
    path = template.withUnsafeMutableBufferPointer { String(cString: mkdtemp($0.baseAddress!)) }
  }

  // A temporary folder left behind only takes space.
  deinit { try? FileManager.default.removeItem(atPath: path) }

  var socketPath: String { path + "/helper.sock" }
}

@discardableResult
func until<T>(timeout: TimeInterval = 10, _ check: () -> T?) throws -> T {
  let started = Date()
  while Date().timeIntervalSince(started) < timeout {
    if let value = check() { return value }
    Thread.sleep(forTimeInterval: 0.02)
  }
  throw TestFailure("Timed out waiting for the expected state")
}

struct TestFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

func parseLine(_ line: String) -> Object? {
  // A line that is not JSON is no message; callers wait for one that is.
  (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? Object
}

func line(_ object: Any) -> String {
  String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]), as: UTF8.self)
}

// Reads newline-framed text from a descriptor on a thread of its own.
private func readLines(_ descriptor: Int32, _ onLine: @escaping @Sendable (String) -> Void, onEnd: @escaping @Sendable () -> Void = {}) {
  Thread {
    var pending = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { break }
      pending.append(contentsOf: buffer[0..<count])
      while let end = pending.firstIndex(of: 0x0A) {
        let text = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
        pending = Data(pending[pending.index(after: end)...])
        if !text.isEmpty { onLine(text) }
      }
    }
    onEnd()
  }.start()
}

// FIONREAD, _IOR('f', 127, int), a macro Swift does not import: how many bytes wait unread in a pipe.
let bytesWaitingRequest: UInt = 0x4004_667F

// A descriptor its reader thread closes once the reads end, and that is used only while open, holding one lock, so no
// write, read or shutdown reaches a number another test in this process has since opened.
final class OwnedDescriptor: @unchecked Sendable {
  // Unchecked: `isOpen` is read and written holding `lock`; `value` is a constant.
  let value: Int32
  private let lock = NSLock()
  private var isOpen = true

  init(_ value: Int32) { self.value = value }

  // Runs `body` with the descriptor while it is open; false once closed.
  @discardableResult
  func ifOpen(_ body: (Int32) -> Void) -> Bool {
    lock.withLock {
      guard isOpen else { return false }
      body(value)
      return true
    }
  }

  func close() {
    lock.withLock {
      guard isOpen else { return }
      isOpen = false
      Darwin.close(value)
    }
  }
}

// One JSON line read from `descriptor` a byte at a time, so nothing after it is taken; nil after `timeout`.
func readLine(_ descriptor: Int32, timeout: TimeInterval) -> Object? {
  let deadline = Date().addingTimeInterval(timeout)
  var bytes: [UInt8] = []
  while Date() < deadline {
    var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    guard poll(&ready, 1, Int32(max(1, deadline.timeIntervalSinceNow * 1000))) > 0 else { continue }
    var byte: UInt8 = 0
    guard Darwin.read(descriptor, &byte, 1) == 1 else { return nil }
    if byte == 0x0A { return parseLine(String(decoding: bytes, as: UTF8.self)) }
    bytes.append(byte)
  }
  return nil
}

private func write(_ descriptor: Int32, _ text: String) {
  let data = Array((text + "\n").utf8)
  var offset = 0
  while offset < data.count {
    let written = data[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    if written <= 0 { return }
    offset += written
  }
}

// A helper that answers on the socket as the test says: a reply object, or nil for no answer. A reply gets the
// request's id unless it names one itself; one with only `raw` is sent as that text instead, as a line. Each hello reports the next of `builds`, the last one from then on,
// or answers with `helloError` when one is given, after `helloDelay` seconds.
final class FakeHelper: @unchecked Sendable {
  private let lock = NSLock()
  private var received: [Object] = []
  private var clients: [Int32] = []
  private var ended = 0
  private var accepted = 0
  private var builds: [String]
  private let listener: Int32

  init(home: TemporaryHome, builds: [String] = [], helloError: Object? = nil, helloDelay: TimeInterval = 0, respond: @escaping @Sendable (Object) -> Object? = { _ in ["result": [:] as Object] }) throws {
    self.builds = builds
    listener = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      for (index, byte) in home.socketPath.utf8.enumerated() { raw[index] = byte }
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, listen(listener, 8) == 0 else { throw TestFailure("Could not listen on \(home.socketPath)") }
    let listening = self.listener
    let helloError = helloError.map(SharedJSON.init)
    Thread { [weak self] in
      while true {
        let client = accept(listening, nil, nil)
        guard client >= 0, let self else { return }
        // A reply to a command that has gone away fails rather than end the test process with SIGPIPE.
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        self.lock.withLock {
          self.clients.append(client)
          self.accepted += 1
        }
        // The reader owns the descriptor: it closes it once the connection has ended, holding the lock under which
        // replies are written, so nothing is ever written to or read from a number another test has since opened.
        readLines(client, { text in
          guard let request = parseLine(text) else { return }
          self.lock.withLock { self.received.append(request) }
          guard let id = request["id"] else { return }
          if request["method"] as? String == "hello" {
            let reply: String
            if let helloError {
              reply = line(["id": id, "error": helloError.value])
            } else {
              var result: Object = ["version": "fake"]
              self.lock.withLock {
                if let build = self.builds.first { result["build"] = build }
                if self.builds.count > 1 { self.builds.removeFirst() }
              }
              reply = line(["id": id, "result": result])
            }
            guard helloDelay > 0 else { return write(client, reply) }
            // Answered from a thread of its own, so this one goes on reading and sees the connection end meanwhile;
            // written holding the lock, and only while the connection is still listed, so never to a closed one.
            let delayed = reply
            let helper = self
            Thread.detachNewThread {
              Thread.sleep(forTimeInterval: helloDelay)
              helper.lock.withLock { if helper.clients.contains(client) { write(client, delayed) } }
            }
            return
          }
          guard var reply = respond(request) else { return }
          if reply.count == 1, let raw = reply["raw"] as? String {
            write(client, raw + "\n")
            return
          }
          if reply["id"] == nil { reply["id"] = id }
          write(client, line(reply))
        }, onEnd: {
          self.lock.withLock {
            self.clients.removeAll { $0 == client }
            self.ended += 1
            close(client)
          }
        })
      }
    }.start()
  }

  var requests: [Object] { lock.withLock { received } }

  // How many connections the command has opened.
  var connectionsMade: Int { lock.withLock { accepted } }

  // How many connections the command has ended, or this helper with disconnectAll.
  var connectionsEnded: Int { lock.withLock { ended } }

  func first(_ method: String) -> Object? { requests.first { $0["method"] as? String == method } }

  func all(_ method: String) -> [Object] { requests.filter { $0["method"] as? String == method } }

  // Drops every connection, as a helper that quits would. Each reader then sees the end and closes its descriptor.
  func disconnectAll() {
    lock.withLock { for client in clients { shutdown(client, SHUT_RDWR) } }
  }

  deinit {
    disconnectAll()
    shutdown(listener, SHUT_RDWR)
    close(listener)
  }
}

// The MCP server as a client runs it: `backstage mcp` with JSON-RPC on stdin and stdout.
final class ServerProcess: @unchecked Sendable {
  let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let lock = NSLock()
  private var messages: [Object] = []
  private var nextId = 1
  private let ended = DispatchSemaphore(value: 0)

  // An empty value in `environment` removes that variable, such as HELPER_NO_START for a command that manages its
  // helper. With `readsOutput` false, nothing reads the command's output, as from a client that stopped reading.
  init(home: TemporaryHome, executable: String = commandBinary, environment: [String: String] = [:], readsOutput: Bool = true) throws {
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["mcp"]
    var env = ProcessInfo.processInfo.environment
    env["HOME"] = home.path
    env["HELPER_TEST_HOME"] = home.path
    env["HELPER_NO_START"] = "1"
    env.merge(environment) { $1 }
    process.environment = env.filter { !$0.value.isEmpty }
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { [ended] _ in ended.signal() }
    try process.run()
    if readsOutput { startReading() }
  }

  // Reads the command's output from here on; once, for a server made with `readsOutput` false.
  func startReading() {
    readLines(output.fileHandleForReading.fileDescriptor) { [weak self] text in
      guard let self, let message = parseLine(text) else { return }
      self.lock.withLock { self.messages.append(message) }
    }
  }

  // For a server made with `readsOutput` false: one line of its output, read directly, or nil after `timeout`.
  func readOneLine(timeout: TimeInterval = 10) -> Object? {
    readLine(output.fileHandleForReading.fileDescriptor, timeout: timeout)
  }

  // Waits until the pipe of its output is full, so its next write blocks: the bytes waiting have stopped growing,
  // well past what one small reply takes.
  func waitUntilOutputIsFull() throws {
    var last = -1
    var steadySince = Date()
    try until { () -> Bool? in
      let now = outputBytesWaiting
      if now != last {
        last = now
        steadySince = Date()
        return nil
      }
      return now >= 16384 && Date().timeIntervalSince(steadySince) >= 0.3 ? true : nil
    }
  }

  // How many bytes of output wait in the pipe unread.
  var outputBytesWaiting: Int {
    var count: Int32 = 0
    _ = ioctl(output.fileHandleForReading.fileDescriptor, bytesWaitingRequest, &count)
    return Int(count)
  }

  deinit { if process.isRunning { process.terminate() } }

  var received: [Object] { lock.withLock { messages } }

  func write(_ text: String) { input.fileHandleForWriting.write(Data((text + "\n").utf8)) }

  // The server may have closed it already.
  func closeInput() { try? input.fileHandleForWriting.close() }

  func waitForExit(timeout: TimeInterval = 10) throws -> (status: Int32, reason: Process.TerminationReason) {
    guard ended.wait(timeout: .now() + timeout) == .success else { throw TestFailure("The server did not end") }
    return (process.terminationStatus, process.terminationReason)
  }

  // Sends a request and returns its answer.
  func request(_ method: String, _ params: Object = [:], timeout: TimeInterval = 15) throws -> Object {
    let id = lock.withLock { () -> Int in
      defer { nextId += 1 }
      return nextId
    }
    write(line(["jsonrpc": "2.0", "id": id, "method": method, "params": params]))
    return try until(timeout: timeout) { received.first { ($0["id"] as? Int) == id } }
  }

  func initialize(_ name: String = "claude-code", _ protocolVersion: String = "2025-06-18") throws -> Object {
    try request("initialize", ["protocolVersion": protocolVersion, "capabilities": [:] as Object, "clientInfo": ["name": name, "version": "1"]])
  }

  func call(_ name: String, _ arguments: Object = [:]) throws -> Object {
    try request("tools/call", ["name": name, "arguments": arguments])["result"] as? Object ?? [:]
  }
}

func textOf(_ result: Object) -> String {
  (result["content"] as? [Object] ?? []).map { $0["text"] as? String ?? "" }.joined(separator: "\n")
}

// A bundle laid out as an installed app in a temporary home: a copy of the command, and in place of the app's
// executable a Mach-O header that only names a build (its linker UUID), so nothing could start it.
struct FakeBundle {
  let path: String
  let build: String

  var command: String { path + "/" + Product.commandRelativePath }

  init(in home: TemporaryHome, named name: String, build uuid: UInt8, handoffRevision: Int? = nil) throws {
    path = home.path + "/\(name).app"
    let manager = FileManager.default
    try manager.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
    try manager.createDirectory(atPath: path + "/Contents/Helpers", withIntermediateDirectories: true)
    try manager.copyItem(atPath: commandBinary, toPath: path + "/" + Product.commandRelativePath)
    let bytes = [UInt8](repeating: uuid, count: 16)
    var header = Data()
    for word: UInt32 in [0xFEED_FACF, 0x0100_000C, 0, 2, 1, 24, 0, 0, 0x1B, 24] { withUnsafeBytes(of: word.littleEndian) { header.append(contentsOf: $0) } }
    header.append(contentsOf: bytes)
    try header.write(to: URL(fileURLWithPath: path + "/Contents/MacOS/" + Product.appExecutableName))
    build = bytes.map { String(format: "%02x", $0) }.joined()
    if let handoffRevision {
      try ([Product.sessionHandoffKey: handoffRevision] as NSDictionary).write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
    }
  }
}

