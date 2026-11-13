// The app list as agents and other socket clients meet it, against the app built for tests in a temporary home:
// apps that are never available, with or without Allow every app, and the client names the activity log keeps.

import Foundation
import Testing

private let neverAvailable = ["com.lastpass.LastPass", "com.apple.Passwords.MenuBarExtra", "app.foreverbeta.backstage"]

// One request on a connection of its own, as any process that reaches the socket sends it.
private func ask(_ home: TemporaryHome, _ method: String, _ params: Object, after hello: Object? = nil) throws -> Object {
  let socket = try RawSocket(home.socketPath)
  var replies = 0
  if let hello {
    socket.send(line(["id": 1, "method": "hello", "params": hello]))
    replies = 1
  }
  socket.send(line(["id": 2, "method": method, "params": params]))
  let lines = try until { () -> [String]? in
    let lines = socket.received.components(separatedBy: "\n").filter { !$0.isEmpty }
    return lines.count > replies ? lines : nil
  }
  return try #require(parseLine(lines[replies]))
}

@Suite struct AppListTests {
  @Test(arguments: [false, true])
  func appsThatAreNeverAvailableStayOut(everyApp: Bool) throws {
    let home = TemporaryHome()
    if everyApp {
      try #"{"allowsEveryApp":true}"#.write(toFile: home.path + "/settings.json", atomically: true, encoding: .utf8)
    }
    let helper = try RealHelper(home: home)
    for bundleId in neverAvailable {
      let listed = try ask(home, "list_apps", ["app": bundleId])
      let app = (listed["result"] as? Object)?["app"] as? Object
      #expect(app?["access"] as? String == "never_available", "\(bundleId): \(listed)")
      #expect((listed["result"] as? Object)?["every_app"] as? Bool == everyApp)

      let added = try ask(home, "approvals_add", ["app": bundleId])
      #expect((added["error"] as? Object)?["code"] as? String == "not_allowed", "\(bundleId): \(added)")
    }
    // A list that is not there is an empty one.
    let list = (try? String(contentsOfFile: home.path + "/approvals.json", encoding: .utf8)) ?? ""
    #expect(neverAvailable.allSatisfy { !list.contains($0) })
    withExtendedLifetime(helper) {}
  }

  @Test(arguments: [String(repeating: "agent-", count: 10_000) + "\n\u{1b}[2J", "settings", "command_line", "You"])
  func theLogKeepsAShortCleanClientName(name: String) throws {
    let home = TemporaryHome()
    let helper = try RealHelper(home: home)
    #expect(try cli(home, "approvals", "add", "com.apple.finder").status == 0)
    _ = try ask(home, "get_window_state", ["app": "com.apple.finder"], after: ["client_name": name])
    let log = try String(contentsOfFile: home.path + "/decisions.jsonl", encoding: .utf8)
    let used = try #require(log.split(separator: "\n").compactMap { parseLine(String($0)) }.first { $0["decision"] as? String == "used" })
    let client = used["client"] as? String
    #expect(client != "settings" && client != "command_line")
    #expect((client?.count ?? 0) <= 40)
    #expect(!(client ?? "").contains("\u{1b}"))
    #expect(log.utf8.count < 1000)
    withExtendedLifetime(helper) {}
  }
}
