// Key combinations and the refused menus: parsing, shortcut matching, the decision from an item's place in the
// menus, and run_actions naming every step before any runs.

@testable import App
import Foundation
import Testing

private func parse(_ text: String) throws -> KeyCombination { try KeyCombination.parse(text) }

private func code(of call: () throws -> Any) -> String? {
  do {
    _ = try call()
    return nil
  } catch let error as HelperError {
    return error.code
  } catch {
    return "\(error)"
  }
}

@Suite struct KeyCombinationTests {
  @Test func readsModifierAliasesAsTheSameModifiers() throws {
    #expect(try parse("command+option+control+shift+s") == parse("cmd+alt+ctrl+shift+s"))
    #expect(try parse("super+s") == parse("cmd+s"))
    #expect(try parse("cmd+shift+s").text == "shift+cmd+s")
  }

  @Test func takesATrailingPlusAsTheKey() throws {
    let plus = try parse("cmd++")
    #expect(plus.key == "+")
    #expect(plus.modifiers == [.cmd])
    #expect(try parse("+") == KeyCombination(modifiers: [], key: "+"))
    #expect(try parse("ctrl+alt++").modifiers == [.ctrl, .alt])
  }

  @Test func spellsKeysOneWay() throws {
    #expect(try parse("page_up") == parse("pageup"))
    #expect(try parse("cmd+enter") == parse("cmd+return"))
    #expect(try parse("ALT+CMD+ESC") == parse("alt+cmd+escape"))
  }

  @Test func refusesUnknownModifiersAndMissingKeys() {
    #expect(code { try parse("hyper+s") } == "invalid_key")
    #expect(code { try parse("cmd++s") } == "invalid_key")
    #expect(code { try parse("") } == "invalid_key")
  }

  @Test func onlyCommandOrControlMakesAShortcut() throws {
    #expect(try parse("cmd+s").isShortcut)
    #expect(try parse("ctrl+a").isShortcut)
    #expect(try !parse("shift+tab").isShortcut)
    #expect(try !parse("return").isShortcut)
  }
}

@Suite struct RefusedShortcutTests {
  @Test func refusesTheAppleMenusOwnShortcuts() throws {
    for text in ["cmd+shift+q", "option+shift+command+q", "ctrl+cmd+q", "cmd+alt+esc", "cmd+alt+shift+escape"] {
      #expect(refusedMenu(for: try parse(text), among: []) == "the Apple menu", "\(text)")
    }
  }

  @Test func refusesAShortcutOfARefusedItemHoweverItIsSpelled() throws {
    let refused = [(shortcut: "shift+cmd+y", menu: "the Services menu")]
    #expect(refusedMenu(for: try parse("command+shift+y"), among: refused) == "the Services menu")
  }

  @Test func allowsOrdinaryShortcuts() throws {
    let refused = [(shortcut: "shift+cmd+y", menu: "the Services menu")]
    for text in ["cmd+s", "cmd+q", "cmd+y", "cmd+alt+q", "escape"] {
      #expect(refusedMenu(for: try parse(text), among: refused) == nil, "\(text)")
    }
  }
}

@Suite struct RefusedMenuPlaceTests {
  @Test func refusesTheAppleMenuAndTheAppMenusSubmenus() {
    #expect(refusedMenu(topIndex: 0, submenuTitles: []) == "the Apple menu")
    #expect(refusedMenu(topIndex: 0, submenuTitles: ["Recent Items"]) == "the Apple menu")
    #expect(refusedMenu(topIndex: 1, submenuTitles: ["Services"]) != nil)
    #expect(refusedMenu(topIndex: 1, submenuTitles: ["Dienste"]) != nil)
  }

  @Test func refusesShareAndServicesSubmenusAnywhere() {
    #expect(refusedMenu(topIndex: 2, submenuTitles: ["Share"]) == "the Share menu")
    #expect(refusedMenu(topIndex: nil, submenuTitles: ["Services"]) != nil)
    #expect(refusedMenu(topIndex: 3, submenuTitles: ["Export", "Share"]) == "the Share menu")
  }

  // The search for refused shortcuts reads a top-level menu whole when it is refused, and otherwise enters only
  // the direct items whose title alone makes them refused.
  @Test func decidesFromATopLevelMenusDirectItemTitles() {
    #expect(refusedMenu(topIndex: 0, submenuTitles: []) != nil)
    #expect(refusedMenu(topIndex: 1, submenuTitles: []) == nil)
    #expect(refusedMenu(topIndex: 2, submenuTitles: []) == nil)
    #expect(refusedMenu(topIndex: 1, submenuTitles: ["Services"]) == "a Services or Share menu")
    #expect(refusedMenu(topIndex: 2, submenuTitles: ["Share"]) == "the Share menu")
    #expect(refusedMenu(topIndex: 5, submenuTitles: ["Services"]) != nil)
    for title in ["Open Recent", "Export", "Find", "Transformations"] {
      #expect(refusedMenu(topIndex: 2, submenuTitles: [title]) == nil, "\(title)")
    }
  }

  @Test func allowsOtherItems() {
    #expect(refusedMenu(topIndex: 1, submenuTitles: []) == nil)
    #expect(refusedMenu(topIndex: 2, submenuTitles: ["Open Recent"]) == nil)
    #expect(refusedMenu(topIndex: nil, submenuTitles: []) == nil)
  }
}

@Suite struct ScrollStepTests {
  @Test func onePageMovesByTheVisibleShare() throws {
    let step = try #require(scrollBarPageStep(visible: 500, content: 2500))
    #expect(abs(step - 0.25) < 1e-9)
    #expect(abs(scrollPosition(from: 0, step: step, pages: 1) - 0.25) < 1e-9)
    let long = try #require(scrollBarPageStep(visible: 100, content: 10100))
    #expect(abs(scrollPosition(from: 0.5, step: long, pages: 1) - 0.51) < 1e-9)
  }

  @Test func staysWithinTheRange() throws {
    let step = try #require(scrollBarPageStep(visible: 500, content: 1000))
    #expect(scrollPosition(from: 0.5, step: step, pages: 3) == 1)
    #expect(scrollPosition(from: 0.5, step: step, pages: -3) == 0)
  }

  @Test func hasNoStepWhenNothingCanScroll() {
    #expect(scrollBarPageStep(visible: 500, content: 500) == nil)
    #expect(scrollBarPageStep(visible: 0, content: 500) == nil)
  }
}

@Suite struct RunActionsTests {
  // A first step that would fail and be reported, so a list checked step by step would answer instead of refusing.
  @Test func refusesAnUnknownStepBeforeRunningAny() {
    let app = AppIdentity(pid: 0, bundleId: "app.example.none", name: "None", launchDate: nil, path: nil)
    let steps: [JSON] = [["tool": "press", "element": 999_999], ["tool": "launch_rockets"]]
    do {
      _ = try runActions(app: app, params: ["steps": steps], session: ApprovalSession())
      Issue.record("The steps ran.")
    } catch let error as HelperError {
      #expect(error.code == "invalid_request")
      #expect(error.message.hasPrefix("Step 2"))
    } catch {
      Issue.record("\(error)")
    }
  }
}
