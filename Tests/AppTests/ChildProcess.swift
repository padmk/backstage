@testable import App
import Foundation
import Testing

// A child that runs until its input closes, and is stopped at the end of the test either way. It has no windows, so
// key events posted to it reach nothing.
func withChild(_ body: (Process, Pipe) throws -> Void) throws {
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
  try body(process, input)
}

// The identity a request decided for, for a child process.
func childIdentity(_ process: Process) throws -> AppIdentity {
  let start = try #require(processStart(of: process.processIdentifier))
  return AppIdentity(pid: process.processIdentifier, bundleId: "test.process", name: "Child", processStart: start, path: nil)
}
