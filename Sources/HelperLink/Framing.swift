// Line-delimited JSON, as the app's socket and MCP over stdio both speak it. A frame ends only at `\n`: raw
// U+2028 and U+2029 are valid inside JSON strings, so a general line reader would split a message on them.

import Foundation

public struct LineFramer: Sendable {
  private var pending = Data()

  public init() {}

  // The complete lines in `chunk` and those before it, without the newline and a trailing `\r`; blank lines are
  // skipped. A frame without its newline waits for the next chunk.
  public mutating func lines(in chunk: Data) -> [String] {
    pending.append(chunk)
    var lines: [String] = []
    while let end = pending.firstIndex(of: 0x0A) {
      var line = pending[pending.startIndex..<end]
      if line.last == 0x0D { line = line.dropLast() }
      pending = Data(pending[pending.index(after: end)...])
      let text = String(decoding: line, as: UTF8.self)
      if !text.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(text) }
    }
    return lines
  }
}

// One JSON object as one line. Sorted keys keep the output stable; `/` stays unescaped, as JavaScript writes it.
public func jsonLine(_ object: Any) -> Data {
  var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? Data("{}".utf8)
  data.append(0x0A)
  return data
}

// Writes all of `data`, retrying after a signal and after a partial write. Returns false when the other side is gone.
@discardableResult
public func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
  data.withUnsafeBytes { buffer in
    guard var base = buffer.baseAddress else { return true }
    var left = buffer.count
    while left > 0 {
      let written = Darwin.write(descriptor, base, left)
      if written < 0 {
        if errno == EINTR { continue }
        return false
      }
      left -= written
      base = base.advanced(by: written)
    }
    return true
  }
}
