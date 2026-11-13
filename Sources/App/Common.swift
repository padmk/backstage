// Types and small helpers shared by the helper's modules.

import Foundation
import HelperLink
import Synchronization

typealias JSON = [String: Any]

struct HelperError: Error {
  let code: String
  let message: String
}

func string(_ params: JSON, _ key: String) throws -> String {
  guard let value = params[key] as? String else {
    throw HelperError(code: "invalid_request", message: "\(key) must be a string.")
  }
  return value
}

func nonEmptyString(_ params: JSON, _ key: String) throws -> String {
  let value = try string(params, key)
  guard !value.isEmpty else { throw HelperError(code: "invalid_request", message: "\(key) is empty.") }
  return value
}

func integer(_ params: JSON, _ key: String) throws -> Int {
  guard let value = params[key] as? Int else {
    throw HelperError(code: "invalid_request", message: "\(key) must be a whole number.")
  }
  return value
}

func number(_ params: JSON, _ key: String) throws -> Double {
  guard let value = params[key] as? Double, value.isFinite else {
    throw HelperError(code: "invalid_request", message: "\(key) must be a number.")
  }
  return value
}

// A framework object that is not Sendable, such as a contact or event store, used by one thread at a time.
// Unchecked: the value is reached only inside `withLock`, holding the lock, and callers keep none of it past the
// closure. Sendable state goes in a Mutex instead, which the compiler checks.
final class Exclusive<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) { self.value = value }

  func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
    try lock.withLock { try body(&value) }
  }
}

// The result of async work that synchronous code waits for until a deadline. The first result set is kept, so a
// cancel that comes first stays the answer.
final class AsyncOutcome<Value: Sendable>: Sendable {
  private let result = Mutex<Result<Value, any Error>?>(nil)
  private let done = DispatchSemaphore(value: 0)

  func set(_ outcome: Result<Value, any Error>) {
    let first = result.withLock { result -> Bool in
      if result != nil { return false }
      result = outcome
      return true
    }
    if first { done.signal() }
  }

  // nil when no result came by the deadline.
  func wait(until deadline: DispatchTime) -> Result<Value, any Error>? {
    guard done.wait(timeout: deadline) == .success else { return nil }
    return result.withLock { $0 }
  }
}

func sleep(seconds: Double) {
  Thread.sleep(forTimeInterval: seconds)
}

// Replaces the file at `path` with `data` in one step, readable only by its owner.
func writePrivateFile(_ data: Data, to path: String) throws {
  let temporary = path + ".\(getpid())"
  guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else {
    throw HelperError(code: "store_failed", message: "Could not write \(temporary).")
  }
  guard rename(temporary, path) == 0 else {
    unlink(temporary)
    throw HelperError(code: "store_failed", message: "Could not replace \(path).")
  }
}

// The product's name and directories come from HelperLink, which the command shares.
enum Configuration {
  static let appName = Product.appName
  // Only a bare test build takes a home of its own (--home). A copy of the app bundle carries the app's identity and
  // grants wherever it lies, so any bundled copy ignores --home and always uses the user's real files.
  private static let startDirectories: Directories = {
    let arguments = CommandLine.arguments
    guard Bundle.main.bundleIdentifier == nil, let index = arguments.firstIndex(of: "--home"), arguments.indices.contains(index + 1) else {
      return Directories()
    }
    return Directories(testHome: arguments[index + 1])
  }()
  // A home of its own for one test, seen only by the code that test runs in its task.
  @TaskLocal static var testDirectories: Directories?
  static var directories: Directories { testDirectories ?? startDirectories }
  static var configHome: String { directories.config }
  static var stateHome: String { directories.state }
  static var socketPath: String { directories.socketPath }
  static var version: String { Product.version }
  // Which build of the app this process runs, so the command can tell when the app was replaced under it.
  static var build: String { ownBuildIdentity }
}
