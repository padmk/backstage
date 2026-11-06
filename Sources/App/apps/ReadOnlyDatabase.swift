// Another app's SQLite database, opened read-only while the app may be writing to it: its write-ahead log is read
// along with it. Ready operations that read an app's own data, such as WhatsApp's chats, use it.

import Foundation
import SQLite3

private let busySeconds: Int32 = 2

final class ReadOnlyDatabase {
  private var handle: OpaquePointer?
  private let appName: String

  init(path: String, appName: String) throws {
    self.appName = appName
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
      sqlite3_close(handle)
      throw HelperError(code: "action_failed", message: "\(appName)'s database could not be opened: \(message).")
    }
    sqlite3_busy_timeout(handle, busySeconds * 1000)
  }

  deinit { sqlite3_close(handle) }

  func columns(of table: String) -> Set<String> {
    Set((try? rows("SELECT name FROM pragma_table_info(?)", [table]))?.compactMap { $0["name"] as? String } ?? [])
  }

  // The columns of each table, failing with unsupported_format when one the operations need is missing: the
  // format is the app's own, and a version that changed it is refused rather than read wrong.
  func requireColumns(_ required: [String: Set<String>], optional: [String] = []) throws -> [String: Set<String>] {
    var found: [String: Set<String>] = [:]
    for table in Set(required.keys).union(optional) { found[table] = columns(of: table) }
    for (table, needed) in required.sorted(by: { $0.key < $1.key }) where !needed.isSubset(of: found[table] ?? []) {
      let missing = needed.subtracting(found[table] ?? []).sorted().joined(separator: ", ")
      throw HelperError(code: "unsupported_format", message: "This \(appName) version keeps its data in a format Backstage does not know (\(table) lacks \(missing)). Use its window instead.")
    }
    return found
  }

  // Each row as column name to String, Int64, Double, Data or nil.
  func rows(_ sql: String, _ bindings: [Any?] = []) throws -> [[String: Any?]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (index, value) in bindings.enumerated() {
      let position = Int32(index + 1)
      switch value {
      case let text as String: sqlite3_bind_text(statement, position, text, -1, transient)
      case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
      case let number as Int64: sqlite3_bind_int64(statement, position, number)
      case let number as Double: sqlite3_bind_double(statement, position, number)
      default: sqlite3_bind_null(statement, position)
      }
    }
    var result: [[String: Any?]] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else { throw failure() }
      var row: [String: Any?] = [:]
      for column in 0..<sqlite3_column_count(statement) {
        let name = String(cString: sqlite3_column_name(statement, column))
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, column)
        case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
        case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, column))
        case SQLITE_BLOB:
          let count = Int(sqlite3_column_bytes(statement, column))
          row[name] = count > 0 ? Data(bytes: sqlite3_column_blob(statement, column), count: count) : Data()
        default: row[name] = nil as Any?
        }
      }
      result.append(row)
    }
    return result
  }

  private func failure() -> HelperError {
    HelperError(code: "action_failed", message: "Reading \(appName)'s database failed: \(String(cString: sqlite3_errmsg(handle))).")
  }
}
