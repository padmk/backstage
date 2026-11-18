// Change reports: only what the lines say counts as a change, and a cut label or value still shows a change past
// the cut.

@testable import App
import ApplicationServices
import Foundation
import Testing

@Suite struct StateChangeReportTests {
  @Test func anElementThatOnlyGotANewNumberIsNoChangeAndComesBackWithItsNewNumber() {
    let before = ["1 Window \"Settings\"", "  2 Button \"General\" [Press]", "  3 CheckBox \"Dark\" value=\"0\""]
    let after = ["1 Window \"Settings\"", "  14 Button \"General\" [Press]", "  15 CheckBox \"Dark\" value=\"0\""]
    let report = changeReport(before: before, after: after)
    #expect(report["changed"] as? Bool == false)
    #expect((report["added"] as? [String])?.isEmpty == true)
    #expect((report["removed"] as? [String])?.isEmpty == true)
    #expect(report["renumbered"] as? [String] == ["14 Button \"General\" [Press]", "15 CheckBox \"Dark\" value=\"0\""])
  }

  @Test func aChangedValueIsReportedAsAddedAndRemoved() {
    let before = ["1 Window \"Settings\"", "  3 CheckBox \"Dark\" value=\"0\""]
    let after = ["1 Window \"Settings\"", "  3 CheckBox \"Dark\" value=\"1\""]
    let report = changeReport(before: before, after: after)
    #expect(report["changed"] as? Bool == true)
    #expect(report["added"] as? [String] == ["3 CheckBox \"Dark\" value=\"1\""])
    #expect(report["removed"] as? [String] == ["3 CheckBox \"Dark\" value=\"0\""])
    #expect(report["renumbered"] == nil)
  }

  @Test func aRenumberedElementNextToARealChangeKeepsTheChangeApart() {
    let before = ["1 Window \"Mail\"", "  2 Row \"Inbox\"", "  3 StaticText value=\"2 unread\""]
    let after = ["1 Window \"Mail\"", "  9 Row \"Inbox\"", "  3 StaticText value=\"3 unread\"", "  10 Row \"Sent\""]
    let report = changeReport(before: before, after: after)
    #expect(report["changed"] as? Bool == true)
    #expect(report["added"] as? [String] == ["3 StaticText value=\"3 unread\"", "10 Row \"Sent\""])
    #expect(report["removed"] as? [String] == ["3 StaticText value=\"2 unread\""])
    #expect(report["renumbered"] as? [String] == ["9 Row \"Inbox\""])
  }

  // A list sorted anew holds the same lines in another order, which no added or removed line shows.
  @Test func theSameLinesInAnotherOrderAreAChange() {
    let before = ["1 List", "  2 Row \"Alpha\"", "  3 Row \"Beta\""]
    let after = ["1 List", "  3 Row \"Beta\"", "  2 Row \"Alpha\""]
    let report = changeReport(before: before, after: after)
    #expect(report["changed"] as? Bool == true)
    #expect(report["reordered"] as? Bool == true)
    #expect(changeReport(before: before, after: before)["reordered"] == nil)
    // Two rows that say the same swap places; only their numbers show it.
    let same = ["1 List", "  2 Row \"Note\"", "  3 Row \"Note\""]
    let swapped = ["1 List", "  3 Row \"Note\"", "  2 Row \"Note\""]
    #expect(changeReport(before: same, after: swapped)["reordered"] as? Bool == true)
    // A row that only got a new number is no reorder.
    #expect(changeReport(before: same, after: ["1 List", "  2 Row \"Note\"", "  9 Row \"Note\""])["reordered"] == nil)
    // A read of the same place returns the whole tree rather than no change.
    #expect(treeDifference(before: before, after: after) == .whole)
    #expect(treeDifference(before: before, after: before) == TreeDifference.none)
    #expect(treeDifference(before: before + ["  4 Row \"Gamma\""], after: before) == .lines(["-   4 Row \"Gamma\""]))
  }

  // A swap next to an insertion: the +/- lines alone would hide the new order.
  @Test func aReorderNextToAnInsertionIsReportedToo() {
    let before = ["1 List", "  2 Row \"Alpha\"", "  3 Row \"Beta\"", "  4 Row \"Gamma\"", "  5 Row \"Delta\""]
    let after = ["1 List", "  3 Row \"Beta\"", "  2 Row \"Alpha\"", "  4 Row \"Gamma\"", "  5 Row \"Delta\"", "  6 Row \"Epsilon\""]
    let report = changeReport(before: before, after: after)
    #expect(report["changed"] as? Bool == true)
    #expect(report["added"] as? [String] == ["6 Row \"Epsilon\""])
    #expect(report["reordered"] as? Bool == true)
    #expect(treeDifference(before: before, after: after) == .whole)
    // The insertion alone keeps the short reply.
    let inserted = before + ["  6 Row \"Epsilon\""]
    #expect(changeReport(before: before, after: inserted)["reordered"] == nil)
    #expect(treeDifference(before: before, after: inserted) == .lines(["+   6 Row \"Epsilon\""]))
    // Rows that only got new numbers, in the same order, are no reorder.
    #expect(!linesReordered(before: before, after: ["1 List", "  12 Row \"Alpha\"", "  13 Row \"Beta\"", "  4 Row \"Gamma\"", "  5 Row \"Delta\""]))
  }

  // Rows that say the same as another one, all renumbered, in another order: none matches by what it says alone.
  @Test func renumberedRowsThatRepeatInAnotherOrderAreAReorder() {
    let before = ["1 List", "  2 Row \"A\"", "  3 Row \"B\"", "  4 Row \"A\""]
    let after = ["1 List", "  12 Row \"A\"", "  14 Row \"A\"", "  13 Row \"B\""]
    #expect(changeReport(before: before, after: after)["reordered"] as? Bool == true)
    #expect(changeReport(before: before, after: after)["changed"] as? Bool == true)
    // Renumbered in their own order, they are no change.
    #expect(changeReport(before: before, after: ["1 List", "  12 Row \"A\"", "  13 Row \"B\"", "  14 Row \"A\""])["changed"] as? Bool == false)
  }

  // Rows that swap places and get new numbers next to an inserted one, among unchanged siblings.
  @Test func aSwapOfRenumberedRowsNextToAnInsertionIsAReorder() {
    let siblings = (0..<5).map { "  \(20 + $0) Row \"Sibling \($0)\"" }
    let before = ["1 List", "  2 Row \"Alpha\"", "  3 Row \"Beta\""] + siblings
    let after = ["1 List", "  31 Row \"Beta\"", "  30 Row \"Alpha\"", "  32 Row \"Gamma\""] + siblings
    let report = changeReport(before: before, after: after)
    #expect(report["reordered"] as? Bool == true)
    #expect(report["added"] as? [String] == ["32 Row \"Gamma\""])
    #expect(treeDifference(before: before, after: after) == .whole)
    // The same rows renumbered in their own order, with the insertion, are no reorder.
    let renumbered = ["1 List", "  30 Row \"Alpha\"", "  31 Row \"Beta\"", "  32 Row \"Gamma\""] + siblings
    #expect(changeReport(before: before, after: renumbered)["reordered"] == nil)
    #expect(!linesReordered(before: before, after: renumbered))
  }

  @Test func aGoneElementIsRemovedEvenWhenAnotherOneSaysTheSame() {
    let before = ["1 List", "  2 Row \"Note\"", "  3 Row \"Note\""]
    let after = ["1 List", "  2 Row \"Note\""]
    let report = changeReport(before: before, after: after)
    #expect(report["changed"] as? Bool == true)
    #expect(report["removed"] as? [String] == ["3 Row \"Note\""])
    #expect((report["added"] as? [String])?.isEmpty == true)
  }

  // Two texts of the same length that differ only past the part a line shows.
  private let first = String(repeating: "a", count: 350) + "first"
  private let second = String(repeating: "a", count: 350) + "other"

  @Test func aChangePastTheCutOfALabelShows() {
    #expect(quoted(first, lengthKey: "label_length") != quoted(second, lengthKey: "label_length"))
    let report = changeReport(before: ["4 StaticText " + quoted(first, lengthKey: "label_length")],
                              after: ["4 StaticText " + quoted(second, lengthKey: "label_length")])
    #expect(report["changed"] as? Bool == true)
  }

  @Test func aChangePastTheCutOfAValueShows() {
    let report = changeReport(before: ["5 TextArea value=" + quoted(first, lengthKey: "length")],
                              after: ["5 TextArea value=" + quoted(second, lengthKey: "length")])
    #expect(report["changed"] as? Bool == true)
  }

  @Test func aCutLabelSaysHowLongItIsAndAShortOneStaysPlain() {
    #expect(quoted("OK", lengthKey: "label_length") == "\"OK\"")
    let cut = quoted(first, lengthKey: "label_length")
    #expect(cut.hasPrefix("\"" + String(repeating: "a", count: maxTextLength) + "…\""))
    #expect(cut.contains(" label_length=355 digest="))
  }
}

// A tree read that stops short of its elements says so, since wait_for with gone and change reports take a tree
// without a partial reason as all there is. Elements are application elements of process ids no process has, read
// through a stand-in.
@Suite struct PartialTreeTests {
  private func render(_ attributes: [pid_t: ElementAttributes], root: pid_t, table: ElementTable = ElementTable()) -> RenderedTree {
    renderTree(roots: [AXUIElementCreateApplication(root)], pid: 1, table: table, maxElements: 10_000, shownToAgent: false) { element in
      var pid: pid_t = 0
      AXUIElementGetPid(element, &pid)
      return attributes[pid] ?? ElementAttributes(values: [:])
    }
  }

  // A chain of buttons, each the only child of the one before, with the text at its end.
  private func chain(_ length: Int, from first: pid_t = 800_000) -> [pid_t: ElementAttributes] {
    var attributes: [pid_t: ElementAttributes] = [:]
    for index in 0..<length {
      let pid = first + pid_t(index)
      var values: [String: AnyObject] = [kAXRoleAttribute: kAXButtonRole as NSString, kAXTitleAttribute: "level \(index)" as NSString]
      if index < length - 1 { values[kAXChildrenAttribute] = [AXUIElementCreateApplication(pid + 1)] as NSArray }
      attributes[pid] = ElementAttributes(values: values)
    }
    return attributes
  }

  @Test func aTreeDeeperThanTheDepthLimitIsPartial() {
    let shallow = render(chain(20), root: 800_000)
    #expect(shallow.partialReason == nil)
    #expect(shallow.lines.count == 20)
    let deep = render(chain(80), root: 800_000)
    #expect(deep.partialReason != nil)
    #expect(!deep.lines.contains { $0.contains("level 79") })
  }

  @Test func anElementWhoseChildrenTheAppDidNotGiveMakesThePartPartial() {
    var attributes = chain(3)
    attributes[800_001] = ElementAttributes(values: [kAXRoleAttribute: kAXButtonRole as NSString], childrenUnreadable: true)
    #expect(render(attributes, root: 800_000).partialReason != nil)
    attributes[800_001] = ElementAttributes(values: [kAXRoleAttribute: "AXGroup" as NSString], childrenUnreadable: true)
    #expect(render(attributes, root: 800_000).partialReason != nil)
  }

  // Numbers past the range the command gave this connection could be another connection's after a helper restart,
  // so the table stops at its end, and a read that needed one more says it is partial.
  @Test func aSessionStopsNumberingAtTheEndOfItsRange() {
    let table = ElementTable()
    table.startNumbering(at: 1_000_001, limit: 1_000_003)
    let attributes = ElementAttributes(values: [kAXRoleAttribute: kAXButtonRole as NSString])
    let numbers = (0..<3).map { table.number(for: AXUIElementCreateApplication(810_000 + $0), pid: 1, shownToAgent: false, attributes: attributes) }
    #expect(numbers == [1_000_001, 1_000_002, nil])
    // An element numbered before keeps its number.
    #expect(table.number(for: AXUIElementCreateApplication(810_000), pid: 1, shownToAgent: false, attributes: attributes) == 1_000_001)
    // A later connection's range goes on from its own start.
    table.startNumbering(at: 2_000_001, limit: 3_000_001)
    #expect(table.number(for: AXUIElementCreateApplication(810_002), pid: 1, shownToAgent: false, attributes: attributes) == 2_000_001)
    let full = ElementTable()
    full.startNumbering(at: 1, limit: 2)
    #expect(render(chain(3), root: 800_000, table: full).partialReason == usedUpNumbers)
  }
}
