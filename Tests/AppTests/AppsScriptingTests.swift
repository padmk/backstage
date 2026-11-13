// Arguments reach a script unchanged through osascript's standard input. The scripts address no app.

@testable import App
import Foundation
import Testing

// osascript can take most of a minute to start on a fresh CI machine, longer than an operation's own limit.
private let firstStart: TimeInterval = 120

private let awkward = "quote \" apostrophe ' newline \n backslash \\ dash -- dollar $HOME ✓"

@Suite struct ScriptingTests {
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
}
