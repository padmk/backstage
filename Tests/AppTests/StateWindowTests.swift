// Window arithmetic and decisions that need no live app: where set_window's layouts put a window, and when a
// pressed close button counts as having closed the window.

@testable import App
import CoreGraphics
import Testing

@Suite struct RequestedFrameTests {
  // A finite frame too large for any screen would reach the window and then trap when the reply rounds it to Int.
  @Test func aFrameBeyondAnyScreenIsRefusedBeforeItReachesTheWindow() throws {
    for box: [String: Any] in [["x": 0, "y": 0, "width": 1e100, "height": 300], ["x": -1e19, "y": 0, "width": 400, "height": 300]] {
      helperError("invalid_request") { try requestedFrame(box) }
    }
    #expect(try requestedFrame(["x": -1920, "y": 25, "width": 800, "height": 600]) == CGRect(x: -1920, y: 25, width: 800, height: 600))
  }

  @Test func aReplyRoundsAnyValueWithoutTrapping() {
    #expect(wholePoints(1e100) == Int(maxScreenCoordinate))
    #expect(wholePoints(-1e100) == -Int(maxScreenCoordinate))
    #expect(wholePoints(.nan) == 0)
    #expect(wholePoints(799.6) == 800)
  }
}

@Suite struct StateWindowTests {
  // A display left of and above the main one, with a 25-point menu bar at the top and an 80-point Dock at the bottom,
  // and an odd size so halves and thirds fall between points.
  private let visible = CGRect(x: -1921, y: -1105, width: 1921, height: 1081 - 25 - 80)
  private let current = CGRect(x: -1500, y: -900, width: 800, height: 600)

  private func frame(_ name: String) throws -> CGRect { try layoutFrame(name, current: current, on: visible) }

  private func expectInside(_ rect: CGRect) {
    let slack: CGFloat = 0.001
    #expect(rect.minX >= visible.minX - slack && rect.maxX <= visible.maxX + slack)
    #expect(rect.minY >= visible.minY - slack && rect.maxY <= visible.maxY + slack)
  }

  private func expectTiles(_ names: [String], columns: Int, rows: Int) throws {
    let frames = try names.map(frame)
    frames.forEach(expectInside)
    let area = frames.reduce(0) { $0 + $1.width * $1.height }
    #expect(abs(area - visible.width * visible.height) < 0.001)
    for (index, rect) in frames.enumerated() {
      for other in frames[(index + 1)...] {
        let overlap = rect.intersection(other)
        #expect(overlap.isNull || overlap.width * overlap.height < 0.001)
      }
    }
    #expect(Set(frames.map(\.minX)).count == columns && Set(frames.map(\.minY)).count == rows)
  }

  @Test func halvesQuartersAndThirdsTileTheVisibleAreaWithoutGaps() throws {
    try expectTiles(["left_half", "right_half"], columns: 2, rows: 1)
    try expectTiles(["top_half", "bottom_half"], columns: 1, rows: 2)
    try expectTiles(["top_left", "top_right", "bottom_left", "bottom_right"], columns: 2, rows: 2)
    try expectTiles(["left_third", "center_third", "right_third"], columns: 3, rows: 1)
    try expectTiles(["left_third", "right_two_thirds"], columns: 2, rows: 1)
    try expectTiles(["left_two_thirds", "right_third"], columns: 2, rows: 1)
    #expect(try abs(frame("left_half").maxX - frame("right_half").minX) < 0.001)
    #expect(try abs(frame("center_third").maxX - frame("right_third").minX) < 0.001)
    #expect(try abs(frame("top_left").maxY - frame("bottom_left").minY) < 0.001)
  }

  @Test func maximizeFillsTheVisibleAreaAndCenterKeepsTheSize() throws {
    #expect(try frame("maximize") == visible)
    let centered = try frame("center")
    expectInside(centered)
    #expect(centered.size == current.size)
    #expect(abs(centered.midX - visible.midX) < 0.001 && abs(centered.midY - visible.midY) < 0.001)
  }

  @Test func centerShrinksAWindowLargerThanTheVisibleArea() throws {
    let centered = try layoutFrame("center", current: CGRect(x: 0, y: 0, width: 4000, height: 3000), on: visible)
    #expect(centered == visible)
  }

  @Test func anUnknownLayoutIsRefused() {
    #expect(throws: HelperError.self) { try frame("left_quarter") }
  }

  private func closed(wasOnScreen: Bool = true, inWindowServer: Bool = true, onScreen: Bool = true,
                      inAccessibility: Bool? = true, minimized: Bool = false, appHidden: Bool = false) -> Bool {
    windowHasClosed(WindowAfterClose(wasOnScreen: wasOnScreen, inWindowServer: inWindowServer, onScreen: onScreen,
                                     inAccessibility: inAccessibility, minimized: minimized, appHidden: appHidden))
  }

  @Test func aWindowTheAppKeepsHiddenAfterClosingCountsAsClosed() {
    #expect(closed(inWindowServer: false))
    // Kept in the window server, no longer drawn and no longer listed by the app, as Music does.
    #expect(closed(onScreen: false, inAccessibility: false))
    // Still listed by the app, but no longer drawn.
    #expect(closed(onScreen: false, inAccessibility: true))
  }

  @Test func aWindowStillThereOrOnlyMinimizedOrHiddenHasNotClosed() {
    #expect(!closed())
    #expect(!closed(onScreen: false, minimized: true))
    #expect(!closed(onScreen: false, inAccessibility: false, appHidden: true))
    #expect(!closed(onScreen: false, inAccessibility: nil, appHidden: true))
    // A window that was not drawn before the press says nothing by not being drawn after it.
    #expect(!closed(wasOnScreen: false, onScreen: false, inAccessibility: true))
    #expect(!closed(wasOnScreen: false, onScreen: false, inAccessibility: nil))
    #expect(closed(wasOnScreen: false, onScreen: false, inAccessibility: false))
  }
}

// A click through the system lands on whatever window is on top; only the window asked for may be there.
@Suite struct ForegroundClickTests {
  private func info(pid: Int, number: Int, owner: String) -> [String: Any] {
    [kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: number, kCGWindowOwnerName as String: owner,
     kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 400, "Height": 300] as [String: CGFloat]]
  }

  @Test func anotherWindowOfTheSameAppOnTopIsRefused() {
    let windows = [info(pid: 42, number: 7, owner: "Notes"), info(pid: 42, number: 9, owner: "Notes")]
    let point = CGPoint(x: 100, y: 100)
    #expect(coveringWindowProblem(windows, at: point, pid: 42, window: 7) == nil)
    #expect(coveringWindowProblem(windows, at: point, pid: 42, window: 9) != nil)
    // Without the window's number, what is on top cannot be told apart.
    #expect(coveringWindowProblem(windows, at: point, pid: 42, window: nil) != nil)
    #expect(coveringWindowProblem([info(pid: 43, number: 7, owner: "Mail")], at: point, pid: 42, window: 7)?.hasPrefix("Mail") == true)
  }

  // An element whose window cannot be read is refused for a click through the system, which would check another window.
  @Test func anElementWithoutItsOwnWindowGetsNoForegroundClick() throws {
    helperError("action_failed") { _ = try clickWindow(own: String?.none, foreground: true) }
    #expect(try clickWindow(own: String?.none, foreground: false) == nil)
    #expect(try clickWindow(own: "window 7", foreground: true) == "window 7")
  }

  // The menu check runs right before each button goes down, so a Share button the first press brought under the
  // point stops the next one, and the press that went down comes up.
  @Test func aMenuDenialAfterAPressStopsTheNextOne() {
    var posted: [String] = []
    var menuChecks = 0
    var windowChecks = 0
    helperError("not_allowed") {
      try pressThroughSystem(count: 3, events: { ("down \($0)", "up \($0)") }, menuCheck: {
        menuChecks += 1
        if menuChecks == 2 { throw HelperError(code: "not_allowed", message: "A Share button is under the point now.") }
      }, windowCheck: { windowChecks += 1 }, post: { event, _ in posted.append(event) })
    }
    #expect(posted == ["down 1", "up 1"])
    #expect(menuChecks == 2 && windowChecks == 1)
  }
}
