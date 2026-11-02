// Running other programs, and naming this command and its app in messages.

import Foundation
import HelperLink

struct ProcessOutput {
  let status: Int32
  let output: String
  let errors: String
}

// Runs a program to its end, with a time limit, and fails with its error output when it does not succeed.
@discardableResult
func runProcess(_ path: String, _ arguments: [String], timeout: TimeInterval = 180, allowFailure: Bool = false) throws -> ProcessOutput {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: path)
  process.arguments = arguments
  let output = Pipe()
  let errors = Pipe()
  process.standardOutput = output
  process.standardError = errors
  process.standardInput = FileHandle.nullDevice
  try process.run()
  // Read while it runs, so a full pipe never blocks it.
  var outputData = Data()
  var errorData = Data()
  let group = DispatchGroup()
  group.enter()
  DispatchQueue.global().async {
    outputData = output.fileHandleForReading.readDataToEndOfFile()
    group.leave()
  }
  group.enter()
  DispatchQueue.global().async {
    errorData = errors.fileHandleForReading.readDataToEndOfFile()
    group.leave()
  }
  let finished = DispatchSemaphore(value: 0)
  process.terminationHandler = { _ in finished.signal() }
  if finished.wait(timeout: .now() + timeout) == .timedOut {
    process.terminate()
    finished.wait()
    group.wait()
    throw HelperFailure(code: nil, message: "\(path) did not finish in time.")
  }
  group.wait()
  let result = ProcessOutput(status: process.terminationStatus, output: String(decoding: outputData, as: UTF8.self),
                             errors: String(decoding: errorData, as: UTF8.self))
  if result.status != 0, !allowFailure {
    let detail = (result.errors.isEmpty ? result.output : result.errors).trimmingCharacters(in: .whitespacesAndNewlines)
    throw HelperFailure(code: nil, message: "\(path) failed: \(detail.prefix(2000))")
  }
  return result
}

// The bundle this command runs from: .../Backstage.app/Contents/Helpers/backstage, links resolved.
func ownBundlePath() -> String? {
  let executable = ((Bundle.main.executablePath ?? CommandLine.arguments[0]) as NSString).resolvingSymlinksInPath
  let bundle = ((executable as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
  let app = (bundle as NSString).deletingLastPathComponent
  guard app.hasSuffix(".app"), executable.hasSuffix("/" + Product.commandRelativePath) else { return nil }
  return app
}

// The build of the app next to this command, read once, when the command starts. A bare build outside a bundle
// has none and does not check builds.
func appBuildOfOwnBundle() -> String? {
  ownBundlePath().flatMap { buildIdentity(ofExecutableAt: $0 + "/Contents/MacOS/" + Product.appExecutableName) }
}

let installedCommandPath = Product.installedAppPath + "/" + Product.commandRelativePath

// How to run this command in a message: its name when that finds the installed one, otherwise its full path.
func commandHint() -> String {
  for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
    let candidate = "\(directory)/\(Product.commandName)"
    guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
    let resolved = (candidate as NSString).resolvingSymlinksInPath
    if resolved == installedCommandPath || resolved.hasSuffix("/" + Product.commandRelativePath) { return Product.commandName }
  }
  return FileManager.default.isExecutableFile(atPath: installedCommandPath) ? installedCommandPath : Product.commandName
}
