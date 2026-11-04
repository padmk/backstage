// Types and small helpers shared by the helper's modules.

import Foundation

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

enum Configuration {
  static var home = NSHomeDirectory() + "/Library/Application Support/Backstage"
  static var socketPath: String { home + "/helper.sock" }
  static var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "helper" }
  static var buildVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
  }
}
