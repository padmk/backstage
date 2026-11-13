// Requests to put an app on the list that arrive over the socket, from the command line or anything else that can
// reach it. The socket does not tell an agent from the user, since both run the same command, so a request only
// waits on the Apps tab until the user adds or declines it there. Removing an app narrows access and stays direct.

import AppKit
import HelperLink

struct ApprovalRequest: Identifiable, Equatable {
  let app: AppIdentity
  let client: String?
  var id: String { app.bundleId }

  static func == (a: ApprovalRequest, b: ApprovalRequest) -> Bool { a.app.bundleId == b.app.bundleId && a.client == b.client }
}

enum ApprovalRequests {
  private static let lock = NSLock()
  private static var waiting: [ApprovalRequest] = []
  // A client asking again and again must not grow the list or keep bringing the window forward.
  private static let maxWaiting = 20

  static var all: [ApprovalRequest] { lock.withLock { waiting } }

  // Returns whether the request is new, so the window comes forward only once for it.
  static func add(_ app: AppIdentity, client: String?) throws -> Bool {
    try lock.withLock {
      if waiting.contains(where: { $0.app.bundleId == app.bundleId }) { return false }
      guard waiting.count < maxWaiting else {
        throw HelperError(code: "busy", message: "Too many apps are waiting for the user's answer in the Backstage window.")
      }
      waiting.append(ApprovalRequest(app: app, client: client))
      return true
    }
  }

  // Returns whether the request was still waiting, so each one is answered once.
  @discardableResult
  static func remove(_ bundleId: String) -> Bool {
    lock.withLock {
      let before = waiting.count
      waiting.removeAll { $0.app.bundleId == bundleId }
      return waiting.count != before
    }
  }
}

// Only a bare build started with --home has a home of its own; any other uses the user's files.
var hasTestHome: Bool {
  Bundle.main.bundleIdentifier == nil && Configuration.directories.approvalsPath != Directories().approvalsPath
}

// An app asked for over the socket: a test build in a home of its own, which holds no permissions, adds it at once;
// any other build shows the request for the user to answer.
func requestAddition(_ app: AppIdentity, client: String?) throws -> JSON {
  if hasTestHome {
    try addToList(app, by: commandLineClient)
    return ["added": app.bundleId, "name": app.name] as JSON
  }
  if app.bundleId.isEmpty || isNeverApproved(app.bundleId) || app.pid == getpid() {
    throw HelperError(code: "not_allowed", message: "\(app.name) is never available to agents.")
  }
  if ApprovalStore.list().contains(where: { $0["bundle_id"] == app.bundleId }), ApprovalGate.access(app) == .allowed {
    return ["added": app.bundleId, "name": app.name, "already": true] as JSON
  }
  if try ApprovalRequests.add(app, client: client) {
    DispatchQueue.main.async { showControlWindow(tab: .apps) }
  }
  return ["pending": app.bundleId, "name": app.name,
          "message": "Waiting for the user to add \(app.name) in the Backstage window, on the Apps tab."] as JSON
}
