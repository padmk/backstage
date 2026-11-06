// The text of an attributed string archived with NSArchiver (a "typedstream"), as Messages keeps a message's body
// in attributedBody. Read by hand, within bounds: the bytes come partly from whoever sent the message, and the
// helper holds Accessibility and Full Disk Access, so it never hands them to an unarchiver.

import Foundation

private let maxArchiveBytes = 1 << 20
private let header = Array("streamtyped".utf8)
private let stringClass = Array("NSString".utf8)
// Between the class name and the string's length: the class version and the type of the value that follows.
private let maxGapToValue = 8
private let stringType: UInt8 = 0x2B  // "+", a string of bytes

// The first NSString's characters, which are the message text; nil for anything else.
func typedstreamText(_ data: Data) -> String? {
  let bytes = [UInt8](data.prefix(maxArchiveBytes + 1))
  guard bytes.count <= maxArchiveBytes, bytes.count > header.count + 2, Array(bytes[2..<(2 + header.count)]) == header,
    let classEnd = firstRange(of: stringClass, in: bytes).map({ $0.upperBound })
  else { return nil }
  guard let type = (classEnd..<min(classEnd + maxGapToValue, bytes.count)).first(where: { bytes[$0] == stringType }) else { return nil }
  var index = type + 1
  guard index < bytes.count else { return nil }
  // A length below 0x80 is one byte; 0x81 and 0x82 announce a 16- or 32-bit little-endian one.
  let length: Int
  switch bytes[index] {
  case 0x81:
    guard index + 2 < bytes.count else { return nil }
    length = Int(bytes[index + 1]) | Int(bytes[index + 2]) << 8
    index += 3
  case 0x82:
    guard index + 4 < bytes.count else { return nil }
    length = (0..<4).reduce(0) { $0 | Int(bytes[index + 1 + $1]) << (8 * $1) }
    index += 5
  case let short where short < 0x80:
    length = Int(short)
    index += 1
  default:
    return nil
  }
  guard length > 0, index + length <= bytes.count else { return nil }
  return String(bytes: bytes[index..<(index + length)], encoding: .utf8)
}

private func firstRange(of needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
  guard haystack.count >= needle.count else { return nil }
  for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
    if Array(haystack[start..<(start + needle.count)]) == needle { return start..<(start + needle.count) }
  }
  return nil
}
