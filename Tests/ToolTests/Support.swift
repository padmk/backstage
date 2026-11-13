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
  (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? Object
}

func line(_ object: Any) -> String {
  String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]), as: UTF8.self)
}

// Reads newline-framed text from a descriptor on a thread of its own.
private func readLines(_ descriptor: Int32, _ onLine: @escaping (String) -> Void, onEnd: @escaping () -> Void = {}) {
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
// request's id unless it names one itself. Each hello reports the next of `builds`, the last one from then on.
final class FakeHelper: @unchecked Sendable {
  private let lock = NSLock()
  private var received: [Object] = []
  private var clients: [Int32] = []
  private var builds: [String]
  private let listener: Int32

  init(home: TemporaryHome, builds: [String] = [], respond: @escaping (Object) -> Object? = { _ in ["result": [:] as Object] }) throws {
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
    Thread { [weak self] in
      while true {
        let client = accept(listening, nil, nil)
        guard client >= 0, let self else { return }
        self.lock.withLock { self.clients.append(client) }
        readLines(client) { text in
          guard let request = parseLine(text) else { return }
          self.lock.withLock { self.received.append(request) }
          guard let id = request["id"] else { return }
          if request["method"] as? String == "hello" {
            var result: Object = ["version": "fake"]
            self.lock.withLock {
              if let build = self.builds.first { result["build"] = build }
              if self.builds.count > 1 { self.builds.removeFirst() }
            }
            write(client, line(["id": id, "result": result]))
            return
          }
          guard var reply = respond(request) else { return }
          if reply["id"] == nil { reply["id"] = id }
          write(client, line(reply))
        }
      }
    }.start()
  }

  var requests: [Object] { lock.withLock { received } }

  func first(_ method: String) -> Object? { requests.first { $0["method"] as? String == method } }

  func all(_ method: String) -> [Object] { requests.filter { $0["method"] as? String == method } }

  // Drops every connection, as a helper that quits would.
  func disconnectAll() {
    let current = lock.withLock { () -> [Int32] in
      defer { clients.removeAll() }
      return clients
    }
    for client in current {
      shutdown(client, SHUT_RDWR)
      close(client)
    }
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
  private let lock = NSLock()
  private var messages: [Object] = []
  private var nextId = 1
  private let ended = DispatchSemaphore(value: 0)

  // An empty value in `environment` removes that variable, such as HELPER_NO_START for a command that manages its
  // helper.
  init(home: TemporaryHome, executable: String = commandBinary, environment: [String: String] = [:]) throws {
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["mcp"]
    var env = ProcessInfo.processInfo.environment
    env["HOME"] = home.path
    env["HELPER_TEST_HOME"] = home.path
    env["HELPER_NO_START"] = "1"
    env.merge(environment) { $1 }
    process.environment = env.filter { !$0.value.isEmpty }
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { [ended] _ in ended.signal() }
    try process.run()
    readLines(output.fileHandleForReading.fileDescriptor) { [weak self] text in
      guard let self, let message = parseLine(text) else { return }
      self.lock.withLock { self.messages.append(message) }
    }
  }

  deinit { if process.isRunning { process.terminate() } }

  var received: [Object] { lock.withLock { messages } }

  func write(_ text: String) { input.fileHandleForWriting.write(Data((text + "\n").utf8)) }

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
