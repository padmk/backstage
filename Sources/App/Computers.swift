// The user's other Macs that agents may reach with `computer`, by the name `ssh` reaches each under. The command
// asks here before it opens ssh to one. Like the app list, the socket cannot tell an agent from the user, so a Mac not
// on the list only waits in the window until the user adds or declines it there; removing one stays direct.

import Foundation
import HelperLink

struct ComputerRequest: Identifiable, Equatable {
  let name: String
  let client: String?
  var id: String { name }
}

enum ComputerList {
  private static let lock = NSLock()
  private static var waiting: [ComputerRequest] = []
  // A client asking again and again must not grow the list or keep bringing the window forward.
  private static let maxWaiting = 20

  // Names are compared without regard to case, as ssh_config and DNS do.
  private static func key(_ name: String) -> String { name.lowercased() }

  static var allowed: [String] { Preferences.allowedComputers }
  static var requests: [ComputerRequest] { lock.withLock { waiting } }

  static func isAllowed(_ name: String) -> Bool { allowed.contains { key($0) == key(name) } }

  static func add(_ name: String, by client: String) {
    lock.withLock {
      waiting.removeAll { key($0.name) == key(name) }
      if !allowed.contains(where: { key($0) == key(name) }) {
        Preferences.allowedComputers = (allowed + [name]).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
      }
    }
    writeDecisionLog(client: client, bundleId: name, decision: "computer_added")
  }

  static func remove(_ name: String, by client: String) {
    let removed = lock.withLock { () -> Bool in
      let before = allowed
      Preferences.allowedComputers = before.filter { key($0) != key(name) }
      return before.count != Preferences.allowedComputers.count
    }
    if removed { writeDecisionLog(client: client, bundleId: name, decision: "computer_removed") }
  }

  // Returns whether the request was still waiting, so each one is answered once.
  @discardableResult
  static func decline(_ name: String, by client: String) -> Bool {
    let was = lock.withLock { () -> Bool in
      let before = waiting.count
      waiting.removeAll { key($0.name) == key(name) }
      return waiting.count != before
    }
    if was { writeDecisionLog(client: client, bundleId: name, decision: "computer_declined") }
    return was
  }

  // Returns whether the request is new, so the window comes forward only once for it.
  fileprivate static func ask(_ name: String, client: String?) throws -> Bool {
    try lock.withLock {
      if waiting.contains(where: { key($0.name) == key(name) }) { return false }
      guard waiting.count < maxWaiting else {
        throw HelperError(code: "busy", message: "Too many requests are waiting for the user's answer in the Backstage window.")
      }
      waiting.append(ComputerRequest(name: name, client: client))
      return true
    }
  }
}

// Whether a call may go to another Mac: one on the list goes on; any other waits for the user in the window, and a
// test build in a home of its own, which holds no permissions, adds it at once.
func requireAllowedComputer(_ name: String, client: String?) throws {
  if let problem = ComputerName.problem(with: name) { throw HelperError(code: "invalid_arguments", message: problem) }
  if ComputerList.isAllowed(name) { return }
  if hasTestHome {
    ComputerList.add(name, by: commandLineClient)
    return
  }
  if try ComputerList.ask(name, client: client) {
    DispatchQueue.main.async { showControlWindow(tab: .apps) }
  }
  throw HelperError(
    code: "computer_not_approved",
    message: "\(name) is not on the user's list of Macs agents may reach, so nothing was sent there. The request waits in the Backstage window on this Mac; tell the user to add \(name) there, and do not reach it another way, such as ssh in the shell.")
}
