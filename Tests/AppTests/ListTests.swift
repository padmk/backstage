// The app list's own rules, called as the helper calls them: client names from hello, apps that are never
// available, the activity log's bounds and answering a waiting request. Files go to a temporary home only.

import Foundation
import HelperLink
import Testing

@testable import App

@Suite struct ClientNameTests {
  @Test func keepsAnOrdinaryName() {
    #expect(sessionClientName("claude-code") == "claude-code")
  }

  @Test func keepsOneShortLine() throws {
    let name = try #require(sessionClientName("agent\n\u{1b}[31m" + String(repeating: "x", count: 100_000)))
    #expect(name.count <= 40)
    #expect(!name.contains("\n") && !name.contains("\u{1b}"))
  }

  @Test(arguments: ["settings", "command_line", "Settings", "COMMAND_LINE", "command-line", "Command line", "you", "You"])
  func cannotPassForTheUserOrTheCommandLine(name: String) {
    #expect(sessionClientName(name) == nil)
  }

  @Test func takesNothingThatIsNotAName() {
    #expect(sessionClientName(nil) == nil)
    #expect(sessionClientName(42) == nil)
    #expect(sessionClientName("") == nil)
    #expect(sessionClientName("\n\t") == nil)
  }
}

private let neverAvailable = [
    "com.apple.Passwords", "com.apple.Passwords.MenuBarExtra", "com.apple.keychainaccess", "com.apple.SecurityAgent",
    "com.apple.loginwindow", "com.apple.tcc.AuthorizationPromptService", "Electrum",
    "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "org.keepassxc.keepassxc",
    "org.keepassx.keepassxc", "com.hicknhacksoftware.MacPass", "me.proton.pass.electron", "in.sinew.Enpass-Desktop",
    "com.lastpass.LastPass", "com.lastpass.lastpassmacdesktop", "com.keepersecurity.passwordmanager", "com.nordsec.nordpass",
    "com.SiberSystems.RoboForm", "com.sibersystems.RoboFormMac", "app.elpass.macos", "com.safeincloud.Safe-In-Cloud.OSX",
    "pw.buttercup.desktop", "net.antelle.keeweb", "com.jumpcloud.pwm.desktop.live", "com.yubico.yubioath", "io.ente.auth.mac",
    "com.ledger.live", "com.sparrowwallet.sparrow", "io.trezor.TrezorSuite", "ch.shiftcrypto.BitBoxApp", "io.atomicwallet",
    "zksnacks.wasabiwallet", "io.bluewallet.bluewallet", "org.bitcoin.Bitcoin-Qt", "COM.LASTPASS.LASTPASS",
]

@Suite struct NeverAvailableTests {
  @Test(arguments: neverAvailable)
  func isNeverAvailable(bundleId: String) {
    #expect(isNeverApproved(bundleId))
  }

  @Test(arguments: ["com.apple.finder", "com.apple.Notes", "com.nordsec.nordvpn", "com.example.passwordsapp"])
  func otherAppsStayAvailable(bundleId: String) {
    #expect(!isNeverApproved(bundleId))
  }
}

// These change the app's directories, which the whole process shares, so they run one at a time.
@Suite(.serialized) struct ListFileTests {
  @Test func everyAppAllowedLeavesThemOut() throws {
    try withTemporaryHome {
      Preferences.allowsEveryApp = true
      for bundleId in neverAvailable {
        let app = AppIdentity(pid: 0, bundleId: bundleId, name: bundleId, processStart: nil, path: nil)
        #expect(ApprovalGate.access(app) == .neverAvailable, "\(bundleId)")
        #expect(throws: HelperError.self) { try addToList(app, by: settingsClient) }
      }
      let other = AppIdentity(pid: 0, bundleId: "com.example.other", name: "Other", processStart: nil, path: nil)
      #expect(ApprovalGate.access(other) == .allowed)
    }
  }

  @Test func staysBoundedInBytesWhateverTheRecords() throws {
    try withTemporaryHome {
      let long = String(repeating: "a", count: 3000)
      for _ in 0..<1500 { writeDecisionLog(client: "agent", bundleId: long, decision: "used") }
      let size = try #require(try FileManager.default.attributesOfItem(atPath: Configuration.directories.decisionLogPath)[.size] as? Int)
      #expect(size <= decisionLogLimit + 4096)
      #expect(recentDecisions(limit: 50).count == 50)
    }
  }

  @Test func skipsAnOversizedOrBrokenLineAndShowsTheRest() throws {
    try withTemporaryHome {
      let path = Configuration.directories.decisionLogPath
      func append(_ data: Data) throws {
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
      }
      func oversized(_ count: Int) -> Data {
        Data(("{\"app\":\"" + String(repeating: "x", count: count) + "\",\"decision\":\"used\"}\n").utf8)
      }
      writeDecisionLog(client: "agent", bundleId: "com.example.first", decision: "used")
      try append(oversized(100_000) + Data([0xff, 0xfe, 0x0a]) + Data("{not json\n".utf8))
      writeDecisionLog(client: "agent", bundleId: "com.example.last", decision: "added")
      #expect(recentDecisions(limit: 50).map(\.bundleId) == ["com.example.last", "com.example.first"])

      // Past the limit, the next write cuts the log back without the oversized line.
      try append(oversized(1_000_000))
      writeDecisionLog(client: "agent", bundleId: "com.example.next", decision: "added")
      let size = try #require(try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
      #expect(size < 4096)
      #expect(recentDecisions(limit: 50).map(\.bundleId) == ["com.example.next", "com.example.last", "com.example.first"])
    }
  }

  @MainActor @Test func aWaitingRequestIsAnsweredOnce() throws {
    try withTemporaryHome {
      let app = AppIdentity(pid: 0, bundleId: "com.example.asked", name: "Asked", processStart: nil, path: nil)
      #expect(try ApprovalRequests.add(app, client: "agent"))
      let request = try #require(ApprovalRequests.all.first { $0.app.bundleId == app.bundleId })
      let model = ControlModel(live: false)
      model.answer(request, add: false)
      model.answer(request, add: false)
      #expect(recentDecisions(limit: 50).map(\.decision) == ["decline"])
      #expect(!ApprovalRequests.all.contains { $0.app.bundleId == app.bundleId })
    }
  }
}

private func withTemporaryHome(_ body: () throws -> Void) throws {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent("list-tests-" + UUID().uuidString).path
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  // A temporary folder left behind only takes space.
  defer { try? FileManager.default.removeItem(atPath: path) }
  try Configuration.$testDirectories.withValue(Directories(testHome: path)) { try body() }
}
