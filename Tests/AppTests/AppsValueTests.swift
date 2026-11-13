// What the app reads out of values agents and other apps hand it: message bodies archived by Messages, times,
// operation arguments and Numbers cell values.

@testable import App
import Foundation
import Testing

// An attributed string as NSArchiver writes it for Messages' attributedBody, with the string's length encoded as
// given and the class chain of an NSMutableString when asked.
private func archive(_ text: [UInt8], length: [UInt8], mutable: Bool = false) -> Data {
  var bytes: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]
  bytes += [0x12] + Array("NSAttributedString".utf8) + [0x00, 0x84, 0x84, 0x08] + Array("NSObject".utf8) + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84]
  if mutable { bytes += [0x0F] + Array("NSMutableString".utf8) + [0x01, 0x84, 0x84] }
  bytes += [0x08] + Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B] + length + text
  return Data(bytes + [0x86, 0x84, 0x02, 0x69, 0x49, 0x01])
}

private func littleEndian(_ value: Int, bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8((value >> (8 * $0)) & 0xFF) } }

@Suite struct TypedstreamTests {
  @Test func readsTheMessageTextForEachLengthEncoding() {
    let short = "Hello 👋"
    #expect(typedstreamText(archive(Array(short.utf8), length: [UInt8(short.utf8.count)])) == short)
    let medium = String(repeating: "a", count: 300)
    #expect(typedstreamText(archive(Array(medium.utf8), length: [0x81] + littleEndian(300, bytes: 2))) == medium)
    let long = String(repeating: "ż", count: 40_000)
    #expect(typedstreamText(archive(Array(long.utf8), length: [0x82] + littleEndian(long.utf8.count, bytes: 4))) == long)
    #expect(typedstreamText(archive(Array("mutable".utf8), length: [7], mutable: true)) == "mutable")
  }

  @Test func givesNothingForArchivesItCannotRead() {
    // Truncated: the length promises more than the archive holds.
    #expect(typedstreamText(archive(Array("abc".utf8), length: [40]).prefix(90)) == nil)
    #expect(typedstreamText(archive([0xFF, 0xFE, 0x41], length: [3])) == nil)
    #expect(typedstreamText(Data("not an archive at all".utf8)) == nil)
    #expect(typedstreamText(Data()) == nil)
    var oversized = archive(Array("abc".utf8), length: [3])
    oversized.append(Data(count: 1 << 20))
    #expect(typedstreamText(oversized) == nil)
  }
}

@Suite struct MomentTests {
  private let warsaw = TimeZone(identifier: "Europe/Warsaw")!

  private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

  @Test func readsDatesAndTimesWithAndWithoutOffsets() throws {
    let day = try moment("2026-11-05", key: "since", in: warsaw)
    #expect(day.isDay && day.date == utc("2026-11-04T23:00:00Z"))
    let local = try moment("2026-11-05T14:30", key: "since", in: warsaw)
    #expect(!local.isDay && local.date == utc("2026-11-05T13:30:00Z"))
    #expect(try moment("2026-07-05T14:30:15", key: "since", in: warsaw).date == utc("2026-07-05T12:30:15Z"))
    #expect(try moment("2026-11-05T14:30:00+05:00", key: "since", in: warsaw).date == utc("2026-11-05T09:30:00Z"))
    #expect(try moment("2026-11-05T14:30:00.250Z", key: "since", in: warsaw).date == utc("2026-11-05T14:30:00Z").addingTimeInterval(0.25))
  }

  @Test func aDayWhoseMidnightIsSkippedStartsAtItsFirstMoment() throws {
    // São Paulo moved its clocks from midnight to 01:00 on 4 November 2018.
    let day = try moment("2018-11-04", key: "since", in: TimeZone(identifier: "America/Sao_Paulo")!)
    #expect(day.isDay && day.date == utc("2018-11-04T03:00:00Z"))
  }

  @Test func refusesDatesThatDoNotExist() {
    for text in ["2026-02-30", "2026-13-01", "tomorrow", "2026-11-05 14:30", ""] {
      helperError("invalid_arguments") { try moment(text, key: "since", in: warsaw) }
    }
  }
}

@Suite struct ArgumentTests {
  private let operation = Operation(
    name: "probe", summary: "", effect: .reads,
    arguments: [
      Argument(name: "mode", kind: .string, required: true, description: "how", allowed: ["fast", "slow"]),
      Argument(name: "count", kind: .integer, required: false, description: "how many", minimum: 1, maximum: 5),
      Argument(name: "flag", kind: .boolean, required: false, description: "whether"),
    ]
  ) { _ in [:] }

  @Test func passesWhatTheOperationDeclares() throws {
    let given = try validated(try json(#"{"mode": "fast", "count": 5, "flag": false}"#), for: operation)
    #expect(given["mode"] as? String == "fast" && given["count"] as? Int == 5 && given["flag"] as? Bool == false)
    #expect(try validated(nil, for: Operation(name: "none", summary: "", effect: .reads, arguments: []) { _ in [:] }).isEmpty)
  }

  @Test func refusesEverythingElseWithTheWholeArgumentList() throws {
    for text in [
      #"{"mode": "fast", "app_id": "com.apple.finder"}"#, #"{"mode": "fast", "other": 1}"#, #"{}"#, #"{"mode": "medium"}"#,
      #"{"mode": 1}"#, #"{"mode": "fast", "count": true}"#, #"{"mode": "fast", "count": 1.5}"#, #"{"mode": "fast", "count": 0}"#,
      #"{"mode": "fast", "count": 6}"#, #"{"mode": "fast", "count": "2"}"#, #"{"mode": "fast", "flag": 1}"#,
    ] {
      let arguments = try json(text)
      let error = helperError("invalid_arguments") { try validated(arguments, for: operation) }
      #expect(error?.message.contains("probe takes: mode (fast|slow, required): how; count (integer): how many; flag (boolean): whether.") == true, "\(text)")
    }
    helperError("invalid_arguments") { try validated([1, 2], for: operation) }
  }
}

@Suite struct CellValueTests {
  @Test func takesTextAndNumbersAsTyped() throws {
    #expect(try cellValues(#"{"b2": "10", "C3": 2.5, "D4": 7, "E5": ""}"#) == ["B2": "10", "C3": "2.5", "D4": "7", "E5": ""])
  }

  @Test func refusesTrueAndFalseAndOtherValues() {
    for text in [#"{"B2": true}"#, #"{"B2": false}"#, #"{"B2": null}"#, #"{"B2": [1]}"#, #"{"B0": "1"}"#, #"{"b2": "1", "B2": "2"}"#, "{}", "[]"] {
      helperError("invalid_arguments") { try cellValues(text) }
    }
  }
}

@Suite struct ContactHandleTests {
  @Test func phoneNumbersKeepTheirDigitsAndLeadingPlus() {
    #expect(ContactHandle("+48 600-100-200") == .phone("+48600100200"))
    #expect(ContactHandle("600 100 200") == .phone("600100200"))
    #expect(ContactHandle("(022) 123.45.67") == .phone("0221234567"))
    #expect(ContactHandle("8080") == .phone("8080"))
  }

  @Test func emailAddressesAreLowercased() {
    #expect(ContactHandle(" Anna@Example.COM ") == .email("anna@example.com"))
  }

  @Test func namesAndIdsAreNoHandles() {
    for other in ["Orange", "INFO-SMS", "chat123456789", "48+111", "+48 +111", "", "١٢٣", "a b@c"] {
      #expect(ContactHandle(other) == nil, "\(other)")
    }
  }

  @Test func searchIgnoresCaseAccentsAndStrokes() {
    #expect(searchFolded("Łódź ZOË Đorđe Øystein") == "lodz zoe dorde oystein")
  }
}
