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
  static var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "helper" }
  // The XDG base directories at their default places, as the command has them. The app starts from
  // launchd too, without the shell's environment, so the XDG_* variables are not read. --home puts both in one.
  // The app list.
  static var configHome = NSHomeDirectory() + "/.config/" + appName.lowercased()
  // The activity log and the socket.
  static var stateHome = NSHomeDirectory() + "/.local/state/" + appName.lowercased()
  static var socketPath: String { stateHome + "/helper.sock" }
  static var buildVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
  }
}
