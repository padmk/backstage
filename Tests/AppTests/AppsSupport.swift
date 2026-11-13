// What the tests of the app's ready operations share: a temporary folder, a writable SQLite database in it, and a
// check of the error code an operation answers with.

@testable import App
import Foundation
import SQLite3
import Testing

// A new folder under the system's temporary folder, removed with everything in it at the end of the test.
final class TemporaryFolder {
  // As the file system names it, links resolved, the way the path rules compare paths.
  let path: String

  init() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("app-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    path = url.resolvingSymlinksInPath().path
  }

  // A temporary folder left behind only takes space.
  deinit { try? FileManager.default.removeItem(atPath: path) }

  // Makes a file with its folders, and gives its path.
  @discardableResult
  func file(_ relative: String, contents: String = "") throws -> String {
    let url = URL(fileURLWithPath: path).appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: false, encoding: .utf8)
    return url.path
  }

  func folder(_ relative: String) throws {
    try FileManager.default.createDirectory(atPath: path + "/" + relative, withIntermediateDirectories: true)
  }

  func link(_ relative: String, to destination: String) throws {
    try FileManager.default.createSymbolicLink(atPath: path + "/" + relative, withDestinationPath: destination)
  }
}

// A database the test fills with plain SQL before the operation reads it.
final class TestDatabase {
  let path: String
  private var handle: OpaquePointer?

  init(in folder: TemporaryFolder, _ statements: String) throws {
    path = folder.path + "/\(UUID().uuidString).sqlite"
    guard sqlite3_open(path, &handle) == SQLITE_OK else { throw TestFailure("could not create \(path)") }
    try run(statements)
  }

  deinit { sqlite3_close(handle) }

  func run(_ statements: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, statements, nil, nil, &error) == SQLITE_OK else {
      defer { sqlite3_free(error) }
      throw TestFailure(error.map { String(cString: $0) } ?? "SQL failed")
    }
  }

  // Binds a blob, which plain SQL cannot hold readably.
  func insert(_ sql: String, blob: Data) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw TestFailure("could not prepare \(sql)") }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(blob.count), transient) }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw TestFailure("could not insert with \(sql)") }
  }
}

struct TestFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

// The HelperError the call throws; it fails the test when the call succeeds or throws anything else.
@discardableResult
func helperError(_ code: String, sourceLocation: SourceLocation = #_sourceLocation, _ call: () throws -> Any) -> HelperError? {
  do {
    let value = try call()
    Issue.record("expected \(code), got \(value)", sourceLocation: sourceLocation)
  } catch let error as HelperError {
    #expect(error.code == code, "\(error.message)", sourceLocation: sourceLocation)
    return error
  } catch {
    Issue.record("expected \(code), got \(error)", sourceLocation: sourceLocation)
  }
  return nil
}

// A time as read back from an operation's ISO 8601 text, whatever zone it was written in.
func instant(_ text: Any?) -> Date? {
  (text as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
}

// JSON as a request carries it, so numbers and booleans arrive as they do from a client.
func json(_ text: String) throws -> JSON {
  try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSON)
}
