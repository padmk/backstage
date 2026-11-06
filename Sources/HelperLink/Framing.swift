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
// With a deadline, for a nonblocking descriptor, it never waits past it: between writes it waits for the descriptor to
// take more for at most the time left (a send timeout would restart while data drains).
@discardableResult
public func writeAll(_ descriptor: Int32, _ data: Data, deadline: Date? = nil) -> Bool {
  data.withUnsafeBytes { buffer in
    guard var base = buffer.baseAddress else { return true }
    var left = buffer.count
    while left > 0 {
      let written = Darwin.write(descriptor, base, left)
      if written < 0 {
        if errno == EINTR { continue }
        guard let deadline, errno == EAGAIN || errno == EWOULDBLOCK else { return false }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        var ready = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let polled = poll(&ready, 1, Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up)))
        if polled < 0, errno != EINTR { return false }
        continue
      }
      left -= written
      base = base.advanced(by: written)
      if let deadline, left > 0, deadline.timeIntervalSinceNow <= 0 { return false }
    }
    return true
  }
}

// Reads what is there, waiting while a nonblocking descriptor has nothing yet. Returns 0 at the end, -1 on an error.
public func readAvailable(_ descriptor: Int32, into buffer: inout [UInt8]) -> Int {
  while true {
    let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
    if count >= 0 { return count }
    if errno == EINTR { continue }
    guard errno == EAGAIN || errno == EWOULDBLOCK else { return -1 }
    var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    if poll(&ready, 1, -1) < 0, errno != EINTR { return -1 }
  }
}
