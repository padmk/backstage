// Change reports: only what the lines say counts as a change, and a cut label or value still shows a change past
// the cut.

@testable import App
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
