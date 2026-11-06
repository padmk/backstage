// Types and small helpers shared by the helper's modules.

import Foundation
import HelperLink

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
  // Set once at start: a test build may put everything in one test home.
  static var directories = Directories()
  static var configHome: String { directories.config }
  static var stateHome: String { directories.state }
  static var socketPath: String { directories.socketPath }
  static var version: String { Product.version }
  // Which build of the app this process runs, so the command can tell when the app was replaced under it.
  static var build: String { ownBuildIdentity }
}
