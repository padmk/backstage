// Key combinations and the refused menus: parsing, shortcut matching, the decision from an item's place in the
// menus, and run_actions naming every step before any runs.

@testable import App
import ApplicationServices
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
    let app = AppIdentity(pid: 0, bundleId: "app.example.none", name: "None", processStart: nil, path: nil)
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

// Menus the check reads through a stand-in for Accessibility: each element is an application element of a process
// id no process has, which the stand-in answers for, so an app that does not answer can be played without one.
private final class FakeMenus {
  private var nextPid: pid_t = 900_000
  private var answers: [pid_t: [String: AttributeRead]] = [:]
  // One read that takes this long, to play an app that answers slowly.
  var slowRead: (element: AXUIElement, name: String, seconds: TimeInterval)?

  func element(_ values: [String: AnyObject] = [:]) -> AXUIElement {
    nextPid += 1
    let element = AXUIElementCreateApplication(nextPid)
    answers[nextPid] = values.mapValues(AttributeRead.value)
    return element
  }

  func set(_ element: AXUIElement, _ name: String, _ read: AttributeRead) {
    answers[pid(element), default: [:]][name] = read
  }

  func set(_ element: AXUIElement, _ name: String, _ value: AnyObject) { set(element, name, .value(value)) }

  var copy: MenuReader.Copy {
    { [self] element, name in
      if let slowRead, CFEqual(slowRead.element, element), slowRead.name == name { Thread.sleep(forTimeInterval: slowRead.seconds) }
      return answers[pid(element)]?[name] ?? .absent
    }
  }

  private func pid(_ element: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    return pid
  }

  // An app with a menu bar of the Apple menu, the app menu with a Services submenu holding one service with
  // shift+cmd+Y, and a File menu with Save (cmd+S).
  struct App {
    let application: AXUIElement
    let bar: AXUIElement
    let appleTop: AXUIElement
    let appTop: AXUIElement
    let servicesItem: AXUIElement
    let service: AXUIElement
    let save: AXUIElement
    let fileTop: AXUIElement
    let lockScreen: AXUIElement
  }

  func app() -> App {
    let application = element([kAXRoleAttribute: kAXApplicationRole as NSString])
    let bar = element([kAXRoleAttribute: kAXMenuBarRole as NSString, kAXParentAttribute: application])
    func top(_ title: String) -> AXUIElement {
      element([kAXRoleAttribute: kAXMenuBarItemRole as NSString, kAXTitleAttribute: title as NSString, kAXParentAttribute: bar])
    }
    func menu(in parent: AXUIElement, _ items: [AXUIElement]) {
      let list = element([kAXRoleAttribute: kAXMenuRole as NSString, kAXParentAttribute: parent, kAXChildrenAttribute: items as NSArray])
      set(parent, kAXChildrenAttribute, [list] as NSArray)
      for item in items { set(item, kAXParentAttribute, list) }
    }
    func item(_ title: String, key: String? = nil, modifiers: Int = 0) -> AXUIElement {
      var values: [String: AnyObject] = [kAXRoleAttribute: kAXMenuItemRole as NSString, kAXTitleAttribute: title as NSString]
      if let key {
        values["AXMenuItemCmdChar"] = key as NSString
        values["AXMenuItemCmdModifiers"] = modifiers as NSNumber
      }
      return element(values)
    }
    let appleTop = top("Apple"), appTop = top("Example"), fileTop = top("File")
    set(bar, kAXChildrenAttribute, [appleTop, appTop, fileTop] as NSArray)
    set(application, kAXMenuBarAttribute, bar)
    let lockScreen = item("Lock Screen", key: "q", modifiers: 4)
    menu(in: appleTop, [item("About This Mac"), lockScreen])
    let servicesItem = item("Services")
    menu(in: appTop, [item("About Example"), servicesItem, item("Quit Example", key: "q")])
    let service = item("Make Sticky", key: "y", modifiers: 1)
    menu(in: servicesItem, [service])
    let save = item("Save", key: "s")
    menu(in: fileTop, [save])
    return App(application: application, bar: bar, appleTop: appleTop, appTop: appTop, servicesItem: servicesItem, service: service, save: save,
               fileTop: fileTop, lockScreen: lockScreen)
  }
}

// What the check answers for a key: nil when it lets the key go, otherwise the error's code.
private func keyCheck(_ text: String, _ menus: FakeMenus, _ app: FakeMenus.App, shortcutSeconds: TimeInterval = refusedSearchSeconds) throws -> String? {
  let combination = try parse(text)
  return code { try requireAllowedKey(combination, application: app.application, appName: "Example", copy: menus.copy, shortcutSeconds: shortcutSeconds) }
}

@Suite struct UnreadableMenuTests {
  @Test func readableMenusRefuseOnlyTheShortcutsOfRefusedItems() throws {
    let menus = FakeMenus()
    let app = menus.app()
    #expect(try keyCheck("shift+cmd+y", menus, app) == "not_allowed")
    #expect(try keyCheck("cmd+s", menus, app) == nil)
    #expect(try keyCheck("return", menus, app) == nil)
  }

  @Test func anAppWithoutAMenuBarHasNoRefusedShortcuts() throws {
    let menus = FakeMenus()
    let app = menus.app()
    menus.set(app.application, kAXMenuBarAttribute, .absent)
    #expect(try keyCheck("shift+cmd+y", menus, app) == nil)
  }

  // A menu bar, a menu or a title the app does not give counts as unread, not as empty: the key is not sent.
  @Test func aShortcutIsRefusedWhenTheMenusItCouldBelongToCannotBeRead() throws {
    for unreadable in [AXError.cannotComplete, .failure] {
      let menus = FakeMenus()
      let app = menus.app()
      menus.set(app.application, kAXMenuBarAttribute, .unreadable(unreadable))
      #expect(try keyCheck("shift+cmd+y", menus, app) != nil, "menu bar, AX error \(unreadable.rawValue)")
    }
    let unreadMenu = FakeMenus()
    let menuApp = unreadMenu.app()
    unreadMenu.set(menuApp.servicesItem, kAXChildrenAttribute, .unreadable(.cannotComplete))
    #expect(try keyCheck("shift+cmd+y", unreadMenu, menuApp) == "timeout")
    let unreadTitle = FakeMenus()
    let titleApp = unreadTitle.app()
    unreadTitle.set(titleApp.servicesItem, kAXTitleAttribute, .unreadable(.cannotComplete))
    #expect(try keyCheck("shift+cmd+y", unreadTitle, titleApp) == "timeout")
    let unreadShortcut = FakeMenus()
    let shortcutApp = unreadShortcut.app()
    unreadShortcut.set(shortcutApp.service, "AXMenuItemCmdChar", .unreadable(.cannotComplete))
    #expect(try keyCheck("shift+cmd+y", unreadShortcut, shortcutApp) == "timeout")
  }

  // One slow answer can outlast the deadline although it started in time: here the scan's last read, the title of
  // the File menu's item, after which nothing else would notice.
  @Test func aReadThatEndsPastTheDeadlineRefuses() throws {
    let menus = FakeMenus()
    let app = menus.app()
    #expect(try keyCheck("cmd+s", menus, app, shortcutSeconds: 0.2) == nil)
    menus.slowRead = (app.save, kAXTitleAttribute, 0.3)
    #expect(try keyCheck("cmd+s", menus, app, shortcutSeconds: 0.2) == "timeout")
  }

  @Test func returnIsRefusedWhenAnOpenMenusSelectionCannotBeRead() throws {
    let menus = FakeMenus()
    let app = menus.app()
    menus.set(app.appTop, kAXSelectedAttribute, kCFBooleanTrue)
    #expect(try keyCheck("return", menus, app) == nil)
    menus.set(app.servicesItem, kAXSelectedAttribute, kCFBooleanTrue)
    #expect(try keyCheck("return", menus, app) == "not_allowed")
    menus.set(app.servicesItem, kAXSelectedAttribute, .unreadable(.cannotComplete))
    #expect(try keyCheck("space", menus, app) == "timeout")
  }

  @Test func textWithASpaceIsRefusedWhenItCannotBeToldWhetherAMenuIsOpen() throws {
    let menus = FakeMenus()
    let app = menus.app()
    let check = { code { try requireNoMenuShown(by: app.application, appName: "Example", copy: menus.copy) } }
    #expect(check() == nil)
    menus.set(app.application, kAXChildrenAttribute, .unreadable(.cannotComplete))
    #expect(check() == "timeout")
    menus.set(app.application, kAXChildrenAttribute, .absent)
    menus.set(app.appTop, kAXSelectedAttribute, .unreadable(.failure))
    #expect(check() == "action_failed")
  }

  // An item whose way up to the menu bar breaks off would otherwise pass for one in a context menu.
  @Test func anItemWhosePlaceCannotBeReadIsRefused() throws {
    let menus = FakeMenus()
    let app = menus.app()
    let reader = { MenuReader(appName: "Example", copy: menus.copy) }
    #expect(code { try requireAllowedMenu(app.save, in: app.application, reader: reader()) } == nil)
    #expect(code { try requireAllowedMenu(app.service, in: app.application, reader: reader()) } == "not_allowed")
    let list = try #require(try reader().element(app.service, kAXParentAttribute))
    menus.set(list, kAXParentAttribute, .unreadable(.cannotComplete))
    #expect(code { try requireAllowedMenu(app.service, in: app.application, reader: reader()) } == "timeout")
  }
}

// The way up from an item decides only when it ends at the menu bar, a window or the app; one that cannot be
// followed there is refused, since the item could be in any menu.
@Suite struct MenuPlaceTests {
  private func check(_ element: AXUIElement, _ menus: FakeMenus, _ app: FakeMenus.App) -> String? {
    code { try requireAllowedMenu(element, in: app.application, reader: MenuReader(appName: "Example", copy: menus.copy)) }
  }

  // A chain of `levels` submenus under `top`, each item opening the next; the last item is returned.
  private func nested(under top: AXUIElement, first title: String, levels: Int, _ menus: FakeMenus) -> AXUIElement {
    var parent = top
    var item = top
    for level in 0..<levels {
      let list = menus.element([kAXRoleAttribute: kAXMenuRole as NSString, kAXParentAttribute: parent])
      item = menus.element([kAXRoleAttribute: kAXMenuItemRole as NSString, kAXTitleAttribute: (level == 0 ? title : "Level \(level)") as NSString,
                            kAXParentAttribute: list])
      menus.set(list, kAXChildrenAttribute, [item] as NSArray)
      menus.set(parent, kAXChildrenAttribute, [list] as NSArray)
      parent = item
    }
    return item
  }

  @Test func allowsItemsAndControlsWhosePlaceIsKnown() {
    let menus = FakeMenus()
    let app = menus.app()
    #expect(check(app.save, menus, app) == nil)
    #expect(check(app.lockScreen, menus, app) == "not_allowed")
    // A button deep in a window's content.
    let window = menus.element([kAXRoleAttribute: kAXWindowRole as NSString, kAXParentAttribute: app.application])
    var parent = window
    for _ in 0..<60 { parent = menus.element([kAXRoleAttribute: kAXGroupRole as NSString, kAXParentAttribute: parent]) }
    let button = menus.element([kAXRoleAttribute: kAXButtonRole as NSString, kAXTitleAttribute: "OK" as NSString, kAXParentAttribute: parent])
    #expect(check(button, menus, app) == nil)
    // An ordinary item of a context menu, which the app holds outside its menu bar.
    let context = menus.element([kAXRoleAttribute: kAXMenuRole as NSString, kAXParentAttribute: app.application])
    let copy = menus.element([kAXRoleAttribute: kAXMenuItemRole as NSString, kAXTitleAttribute: "Copy" as NSString, kAXParentAttribute: context])
    #expect(check(copy, menus, app) == nil)
    // An item of the app's own status menu.
    let extras = menus.element([kAXRoleAttribute: kAXMenuBarRole as NSString, kAXParentAttribute: app.application])
    menus.set(app.application, "AXExtrasMenuBar", extras)
    let status = menus.element([kAXRoleAttribute: kAXMenuBarItemRole as NSString, kAXParentAttribute: extras])
    menus.set(extras, kAXChildrenAttribute, [status] as NSArray)
    let quit = nested(under: status, first: "Quit", levels: 1, menus)
    #expect(check(quit, menus, app) == nil)
  }

  @Test func refusesAnItemWithoutAParent() {
    let menus = FakeMenus()
    let app = menus.app()
    let orphan = menus.element([kAXRoleAttribute: kAXMenuItemRole as NSString, kAXTitleAttribute: "Restart…" as NSString])
    #expect(check(orphan, menus, app) == "not_allowed")
    // Its menu kept, but the menu's own parent gone.
    let list = menus.element([kAXRoleAttribute: kAXMenuRole as NSString, kAXChildrenAttribute: [orphan] as NSArray])
    menus.set(orphan, kAXParentAttribute, list)
    #expect(check(orphan, menus, app) == "not_allowed")
  }

  // The Apple menu reached through a menu bar whose items leave it out, or through a menu bar not the app's.
  @Test func refusesAnAppleMenuItemTheMenuBarDoesNotList() {
    let menus = FakeMenus()
    let app = menus.app()
    menus.set(app.bar, kAXChildrenAttribute, [app.appTop, app.fileTop] as NSArray)
    #expect(check(app.lockScreen, menus, app) == "not_allowed")
    let other = FakeMenus()
    let otherApp = other.app()
    other.set(otherApp.application, kAXMenuBarAttribute, .absent)
    #expect(check(otherApp.lockScreen, other, otherApp) == "not_allowed")
  }

  @Test func refusesAnItemUnderAShareMenuBeyondTheDepthBound() {
    let menus = FakeMenus()
    let app = menus.app()
    let near = nested(under: app.fileTop, first: "Share", levels: 3, menus)
    #expect(check(near, menus, app) == "not_allowed")
    let far = nested(under: app.fileTop, first: "Share", levels: 140, menus)
    #expect(check(far, menus, app) == "not_allowed")
    let ordinary = nested(under: app.fileTop, first: "Export", levels: 3, menus)
    #expect(check(ordinary, menus, app) == nil)
  }

  // A key that confirms a selection deeper than the search reads would confirm an item nobody checked.
  @Test func refusesAConfirmingKeyWhenTheSelectionNestsTooDeep() throws {
    let menus = FakeMenus()
    let app = menus.app()
    var item = app.fileTop
    menus.set(app.fileTop, kAXSelectedAttribute, kCFBooleanTrue)
    var parent = app.fileTop
    for level in 0..<20 {
      let list = menus.element([kAXRoleAttribute: kAXMenuRole as NSString, kAXParentAttribute: parent])
      item = menus.element([kAXRoleAttribute: kAXMenuItemRole as NSString, kAXTitleAttribute: "Level \(level)" as NSString,
                            kAXParentAttribute: list, kAXSelectedAttribute: kCFBooleanTrue])
      menus.set(list, kAXChildrenAttribute, [item] as NSArray)
      menus.set(parent, kAXChildrenAttribute, [list] as NSArray)
      parent = item
    }
    #expect(try keyCheck("return", menus, app) == "not_allowed")
  }
}
