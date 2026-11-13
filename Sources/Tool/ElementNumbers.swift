// Where a session's element numbers come from. Each connection to a helper numbers from a range of its own, so a
// number read before a helper restart, a handoff or a reconnection to another Mac never names an element of the
// new one. The ranges nest: a Mac reached again numbers from a base of its own, above which each handoff of the
// command there and then each of its connections take a slot. A counter that would run past its slot is refused
// rather than reusing a range another one owns, and so is a number past what clients read exactly from JSON.

enum ElementNumbers {
  static let perConnection = 1_000_000
  static let perHandoff = 100_000_000
  static let perRemoteReopen = 10_000_000_000
  static let remoteReopensPerGeneration = 1000
  // JSON numbers above 2^53 lose digits in clients that read them as doubles.
  static let exactLimit = 1 << 53

  // The range a connection numbers from: `base` is where another Mac's command started this session, `generation`
  // the handoffs that brought it here and `connection` the connections this process made before.
  static func connectionRange(base: Int, generation: Int, connection: Int) throws -> Range<Int> {
    guard connection < perHandoff / perConnection else {
      throw used("connected to the helper \(connection) times since its last handoff")
    }
    guard base == 0 || generation < perRemoteReopen / perHandoff else {
      throw used("been handed over \(generation) times on this Mac")
    }
    let first = base + generation * perHandoff + connection * perConnection + 1
    guard first <= exactLimit - perConnection else { throw used("been handed over \(generation) times") }
    return first..<(first + perConnection)
  }

  // Where another Mac's command numbers from when this session opens a connection to it again: `reopened` counts
  // the reopenings in this handoff, from 1.
  static func remoteBase(generation: Int, reopened: Int) throws -> Int {
    guard reopened < remoteReopensPerGeneration else {
      throw used("reconnected to that Mac \(reopened) times since its last handoff")
    }
    let base = (generation * remoteReopensPerGeneration + reopened) * perRemoteReopen
    guard base <= exactLimit - perRemoteReopen else { throw used("been handed over \(generation) times") }
    return base
  }

  private static func used(_ what: String) -> HelperFailure {
    HelperFailure(code: nil, message: "This session has \(what), so it has no element numbers left that no earlier connection used. Start a new session.")
  }
}
