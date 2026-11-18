import CoreGraphics
import Foundation
import Testing

@testable import App

@Suite struct ProcessIdentityTests {
  @Test func aRunningProcessDoesNotNeedALaunchServicesRecord() throws {
    try withChild { process, input in
      let start = try #require(processStart(of: process.processIdentifier))
      let app = AppIdentity(pid: process.processIdentifier, bundleId: "test.process", name: "Child", processStart: start, path: nil)
      try requireSameProcess(app)
      let changed = AppIdentity(pid: app.pid, bundleId: app.bundleId, name: app.name,
        processStart: ProcessStart(seconds: start.seconds + 1, microseconds: start.microseconds), path: nil)
      #expect(throws: HelperError.self) { try requireSameProcess(changed) }
      let unknown = AppIdentity(pid: app.pid, bundleId: app.bundleId, name: app.name, processStart: nil, path: nil)
      #expect(throws: HelperError.self) { try requireSameProcess(unknown) }
      try input.fileHandleForWriting.close()
      process.waitUntilExit()
      #expect(throws: HelperError.self) { try requireSameProcess(app) }
    }
  }

  // launchd runs as root, so the kernel does not describe it to this process: that is no exit.
  @Test func aProcessTheKernelDoesNotDescribeHasNotExited() throws {
    #expect(processState(of: 1) == .unreadable)
    let launchd = AppIdentity(pid: 1, bundleId: "test.process", name: "launchd", processStart: ProcessStart(seconds: 1, microseconds: 0), path: nil)
    #expect { _ = try runningApplication(launchd) } throws: { ($0 as? HelperError)?.code == "action_failed" }
  }

  @Test func aStartTimeIsTakenOnlyForTheDescribedExecutable() throws {
    try withChild { process, _ in
      let pid = process.processIdentifier
      let own = try #require(executablePath(of: pid))
      #expect(processStart(of: pid, running: own) == processStart(of: pid))
      #expect(processStart(of: pid, running: "/bin/ls") == nil)
      #expect(processStart(of: pid, running: nil) == nil)
    }
  }

  @Test func aMissingLaunchServicesRecordForALiveProcessIsNoExit() throws {
    try withChild { process, input in
      let start = try #require(processStart(of: process.processIdentifier))
      let app = AppIdentity(pid: process.processIdentifier, bundleId: "test.process", name: "Child", processStart: start, path: nil)
      // LaunchServices has no record of a plain child process, as it sometimes lacks one for a live app.
      #expect(processState(of: app.pid) == .running(start))
      #expect { _ = try runningApplication(app) } throws: { ($0 as? HelperError)?.code == "action_failed" }
      try input.fileHandleForWriting.close()
      process.waitUntilExit()
      #expect(processState(of: app.pid) == .exited)
      #expect(try runningApplication(app) == nil)
    }
  }

  // Input reaches a pid only while it runs the process the request was decided for: refused before anything went out,
  // and once some of it went out, stopped with the outcome unknown.
  @Test func inputGoesOnlyToTheSameProcess() throws {
    try withChild { process, input in
      let app = try childIdentity(process)
      let tab = try KeyCombination.parse("tab")
      try postKey(tab, app: app)
      try postText("ab", app: app)
      let other = AppIdentity(pid: app.pid, bundleId: app.bundleId, name: app.name,
        processStart: ProcessStart(seconds: try #require(app.processStart).seconds + 1, microseconds: 0), path: nil)
      #expect { try postKey(tab, app: other) } throws: { ($0 as? HelperError)?.code == "app_changed" }
      #expect { try postText("ab", app: other) } throws: { ($0 as? HelperError)?.code == "app_changed" }
      let target = PointerTarget(window: nil, origin: .zero)
      #expect { try postClick(at: .zero, target: target, app: other, count: 1) } throws: { ($0 as? HelperError)?.code == "app_changed" }

      let typing = ProcessInput(app)
      let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
      try typing.postKey(event, try beginEffect())
      try input.fileHandleForWriting.close()
      process.waitUntilExit()
      #expect { try typing.postKey(event, try beginEffect(), progress: "1 characters were typed") } throws: {
        ($0 as? HelperError)?.code == "outcome_unknown" && ($0 as? HelperError)?.message.contains("1 characters were typed") == true
      }
      #expect { try postText("ab", app: app) } throws: { ($0 as? HelperError)?.code == "app_changed" }
    }
  }
}
