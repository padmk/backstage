import Foundation
import Testing

@testable import App

@Suite struct ProcessIdentityTests {
  @Test func aRunningProcessDoesNotNeedALaunchServicesRecord() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/cat")
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }
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
