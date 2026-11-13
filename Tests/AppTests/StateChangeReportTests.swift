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
