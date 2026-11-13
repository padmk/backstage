// Arguments reach a script unchanged through osascript's standard input, and a failure after a script said its
// change began is outcome_unknown. The scripts address no app.

@testable import App
import Foundation
import Testing

// osascript can take most of a minute to start on a fresh CI machine, longer than an operation's own limit.
private let firstStart: TimeInterval = 120

private let awkward = "quote \" apostrophe ' newline \n backslash \\ dash -- dollar $HOME ✓"

// One script at a time: osascript's first start on a fresh CI machine is slow, and several at once there did not
// finish within the limit at all.
@Suite(.serialized) struct ScriptingTests {
  @Test func javaScriptGetsItsArgumentsUnchanged() throws {
    let arguments: JSON = ["text": awkward, "count": 3, "list": ["a", ""]]
    let echoed = try #require(try runScript("return args;", arguments: arguments, target: "osascript", timeout: firstStart) as? JSON)
    #expect(echoed["text"] as? String == awkward && echoed["count"] as? Int == 3 && echoed["list"] as? [String] == ["a", ""])
  }

  @Test func appleScriptGetsItsArgumentsAsAList() throws {
    let source = """
      on main(argv)
        return ((count of argv) as text) & "|" & (item 1 of argv) & "|" & (item 2 of argv)
      end main
      """
    #expect(try runAppleScript(source, arguments: [awkward, ""], target: "osascript", timeout: firstStart) == "2|\(awkward)|")
  }

  // An app's error in the read-back after a write, here one with a code of its own, must not read as nothing done.
  @Test func aFailureAfterTheChangeBeganIsOutcomeUnknownWithItsDetails() throws {
    let error = helperError("outcome_unknown") {
      try runScript("""
        changeBegins({ document: args.document, cell: 'B2' });
        const failure = new Error("Can't get object."); failure.errorNumber = -1728; throw failure;
        """, arguments: ["document": "doc-1"], target: "Numbers", timeout: firstStart)
    }
    #expect(error?.message.contains("doc-1") == true)
    #expect(error?.message.contains("B2") == true)
    helperError("outcome_unknown") {
      try runScript("changeBegins({}); throw new Error('not_found: The table has no cell B2.');", target: "Numbers", timeout: firstStart)
    }
    helperError("outcome_unknown") {
      try runScript("changeBegins({}); ObjC.import('stdlib'); $.exit(1);", target: "Numbers", timeout: firstStart)
    }
  }

  @Test func aFailureBeforeTheChangeBeganKeepsItsCode() throws {
    helperError("not_found") {
      try runScript("throw new Error('not_found: The table has no cell B2.'); changeBegins({});", target: "Numbers", timeout: firstStart)
    }
    helperError("not_found") {
      try runScript("const failure = new Error('gone'); failure.errorNumber = -1728; throw failure;", target: "Numbers", timeout: firstStart)
    }
    #expect(try runScript("changeBegins({ cell: 'B2' }); return 'done';", target: "Numbers", timeout: firstStart) as? String == "done")
  }

  @Test func aScriptThatOverrunsAfterTheChangeBeganIsOutcomeUnknown() throws {
    _ = try runScript("return 1;", target: "osascript", timeout: firstStart)
    helperError("outcome_unknown") { try runScript("changeBegins({}); delay(5); return 1;", target: "Numbers", timeout: 2) }
    helperError("timeout") { try runScript("delay(5); return 1;", target: "Numbers", timeout: 2) }
  }

  @Test func appleScriptReportsAFailureAfterItsChangeBeganWithTheDetailsGiven() throws {
    let source = """
      on main(argv)
        my changeBegins()
        error "Can't get chat." number -1728
      end main
      """
    let error = helperError("outcome_unknown") {
      try runAppleScript(source, arguments: [], target: "Messages", timeout: firstStart, changeDetails: ["to": "chat-7"])
    }
    #expect(error?.message.contains("chat-7") == true)
    helperError("not_found") {
      try runAppleScript("on main(argv)\n  error \"Can't get chat.\" number -1728\nend main", arguments: [], target: "Messages", timeout: firstStart)
    }
  }

  // A document whose file the app does not give is not one without a file: Pages and Numbers refuse it.
  @Test func aDocumentWhoseFileCannotBeReadIsNotTakenForOneWithoutAFile() throws {
    let found = try #require(try runScript(documentFile + """
      return [fileOf({ file() { const failure = new Error('No answer.'); failure.errorNumber = -1712; throw failure; } }),
        fileOf({ file() { return null; } }), fileOf({ file() { return { toString() { return '/Users/someone/a.numbers'; } }; } })];
      """, target: "Numbers", timeout: firstStart) as? [Any])
    #expect(found.count == 3)
    #expect(found.first is NSNull)
    #expect(found.dropFirst().map { $0 as? String } == ["", "/Users/someone/a.numbers"])
    helperError("action_failed") { try reachableDocumentPath(found[0]) }
  }
}

@Suite struct ChildOutputTests {
  // A child that exits while a process it started still holds its output has not given its whole result, so what was
  // read so far never counts as one.
  @Test func outputKeptOpenByAGrandchildIsNotTakenAsTheResult() {
    #expect {
      try runProcess("/bin/sh", ["-c", "echo started; sleep 4 &"], target: "sh", timeout: 10)
    } throws: { error in
      (error as? HelperError)?.code == "outcome_unknown"
    }
  }

  // A process the child started with its output elsewhere would go on working after the reply and the app's lock;
  // it is stopped before runProcess returns, and the result is not taken as the child's whole effect.
  @Test func aProcessTheChildLeftRunningIsStoppedBeforeTheReply() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) } // A leftover temporary folder only takes space.
    let late = folder.appendingPathComponent("late").path
    #expect {
      try runProcess("/bin/sh", ["-c", "(sleep 2; touch '\(late)') >/dev/null 2>&1 &"], target: "sh", timeout: 10)
    } throws: { error in
      (error as? HelperError)?.code == "outcome_unknown"
    }
    Thread.sleep(forTimeInterval: 2.5)
    #expect(!FileManager.default.fileExists(atPath: late))
  }

  @Test func aChildThatLeavesNothingBehindKeepsItsResult() throws {
    let finished = try runProcess("/bin/sh", ["-c", "echo done; exit 3"], target: "sh", timeout: 10)
    #expect(finished.status == 3)
    #expect(finished.output == "done\n")
  }
}
