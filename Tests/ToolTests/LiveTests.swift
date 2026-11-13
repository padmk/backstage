// The real command and the installed app operating a real app in the background, with LIVE=1. They need the app
// installed with Accessibility (`make install`) and the fixture app on the list: the fixture is signed with this
// Mac's Backstage certificate, so the list keeps it across builds once the user has added it in the Backstage
// window, which the first run asks for. Results come from the fixture's own log, never from the reply.
// The steps share one fixture and run in order, as one test. BENCH=1 measures latency instead (see bench/README.md).

import Darwin
import Foundation
import Testing

let fixtureBundleId = "app.foreverbeta.backstage.fixture"
let fixtureName = "Test Fixture"
private let fixtureSource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("Fixtures/target/main.swift").path

// The fixture app, built into a bundle of its own and opened in the background, logging to a file.
final class Fixture {
  let directory = TemporaryHome()
  var bundle: String { directory.path + "/\(fixtureName).app" }
  var logPath: String { directory.path + "/fixture.jsonl" }

  init() throws {
    let macOS = bundle + "/Contents/MacOS"
    try FileManager.default.createDirectory(atPath: macOS, withIntermediateDirectories: true)
    try run("/usr/bin/swiftc", [fixtureSource, "-o", macOS + "/fixture"])
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>\(fixtureBundleId)</string>
    <key>CFBundleName</key><string>\(fixtureName)</string>
    <key>CFBundleExecutable</key><string>fixture</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    </dict></plist>
    """.write(toFile: bundle + "/Contents/Info.plist", atomically: true, encoding: .utf8)
    try sign(bundle)
    try run("/usr/bin/open", ["-g", "-j", "-n", bundle, "--args", logPath])
    _ = try until(timeout: 15) { events("ready").count == 1 ? true : nil }
  }

  func events() -> [Object] {
    // No log yet means no events yet.
    guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { parseLine(String($0)) }
  }

  func events(_ name: String) -> [Object] { events().filter { $0["event"] as? String == name } }

  deinit {
    // A fixture that is not running has nothing to stop.
    _ = try? run("/usr/bin/pkill", ["-f", bundle + "/Contents/MacOS/fixture"])
  }
}

// With this Mac's Backstage signing identity when there is one, so the app list knows the fixture by that
// certificate across builds; ad hoc otherwise.
private func sign(_ bundle: String) throws {
  let data = NSHomeDirectory() + "/.local/share/backstage"
  // No identity file means no Backstage certificate on this Mac; the fixture stays signed ad hoc.
  if let hash = try? String(contentsOfFile: data + "/signing.identity", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
     FileManager.default.fileExists(atPath: data + "/signing.keychain-db") {
    try run("/usr/bin/security", ["unlock-keychain", "-p", "", data + "/signing.keychain-db"])
    try run("/usr/bin/codesign", ["--force", "--sign", hash, "--keychain", data + "/signing.keychain-db", bundle])
  } else {
    try run("/usr/bin/codesign", ["--force", "--sign", "-", bundle])
  }
}

// The fixture on the list, or a request for the user to add it, which the run then stops for.
func requireFixtureOnList(_ server: LiveServer) throws {
  let state = parseLine(textOf(try server.call("list_apps", ["app": fixtureBundleId], app: nil))) ?? [:]
  guard ((state["app"] as? Object)?["access"] as? String) != "allowed" else { return }
  try realCli("approvals", "add", fixtureBundleId)
  throw TestFailure("Add \(fixtureName) in the Backstage window, on the Apps tab, then run this again. Once added, it stays.")
}

@discardableResult
func run(_ path: String, _ arguments: [String]) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: path)
  process.arguments = arguments
  let output = Pipe()
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  try process.run()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { throw TestFailure("\(path) \(arguments.joined(separator: " ")) failed") }
  return String(decoding: data, as: UTF8.self)
}

// The command against the user's real files and the installed app, as an MCP client runs it.
final class LiveServer {
  let process = Process()
  private let input = Pipe()
  private let lock = NSLock()
  private var messages: [Int: Object] = [:]
  private var nextId = 1
  // Signalled for each reply, so a wait ends as soon as its answer arrives rather than at the next poll.
  private let arrived = NSCondition()

  init(command: String = ProcessInfo.processInfo.environment["LIVE_COMMAND"] ?? commandBinary) throws {
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = ["mcp"]
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let descriptor = output.fileHandleForReading.fileDescriptor
    Thread { [weak self] in
      var pending = Data()
      var buffer = [UInt8](repeating: 0, count: 65536)
      while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count > 0, let self else { return }
        pending.append(contentsOf: buffer[0..<count])
        while let end = pending.firstIndex(of: 0x0A) {
          if let message = parseLine(String(decoding: pending[pending.startIndex..<end], as: UTF8.self)), let id = message["id"] as? Int {
            self.arrived.lock()
            self.lock.withLock { self.messages[id] = message }
            self.arrived.broadcast()
            self.arrived.unlock()
          }
          pending = Data(pending[pending.index(after: end)...])
        }
      }
    }.start()
    _ = try request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:] as Object, "clientInfo": ["name": "backstage-live-test", "version": "1"]])
  }

  deinit { process.terminate() }

  func request(_ method: String, _ params: Object, timeout: TimeInterval = 200) throws -> Object {
    let id = lock.withLock { () -> Int in
      defer { nextId += 1 }
      return nextId
    }
    input.fileHandleForWriting.write(Data((line(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) + "\n").utf8))
    let deadline = Date().addingTimeInterval(timeout)
    arrived.lock()
    defer { arrived.unlock() }
    while true {
      if let message = lock.withLock({ messages[id] }) { return message }
      guard arrived.wait(until: deadline) else { throw TestFailure("No answer to \(method) in time") }
    }
  }

  func call(_ name: String, _ arguments: Object = [:], app: String? = fixtureBundleId) throws -> Object {
    var given = arguments
    if let app { given["app"] = app }
    return try request("tools/call", ["name": name, "arguments": given])["result"] as? Object ?? [:]
  }

  // Full trees, since these checks look for elements; reading only the changes is checked by hand.
  func read(_ arguments: Object = [:]) throws -> String {
    var given = arguments
    given["full"] = true
    return textOf(try call("get_window_state", given))
  }
}

func number(of pattern: String, in tree: String) throws -> Int {
  guard let found = tree.split(separator: "\n").first(where: { $0.range(of: pattern, options: .regularExpression) != nil }),
        let number = Int(found.trimmingCharacters(in: .whitespaces).split(separator: " ")[0]) else {
    throw TestFailure("No element matches \(pattern) in:\n\(tree)")
  }
  return number
}

func frontApp() throws -> String {
  let front = try run("/usr/bin/lsappinfo", ["front"]).trimmingCharacters(in: .whitespacesAndNewlines)
  return try run("/usr/bin/lsappinfo", ["info", "-only", "bundleid", front]).trimmingCharacters(in: .whitespacesAndNewlines)
}

// The command against the user's real files, for the app list.
func realCli(_ arguments: String...) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LIVE_COMMAND"] ?? commandBinary)
  process.arguments = arguments
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
}

private let live = ProcessInfo.processInfo.environment["LIVE"] == "1"

@Suite(.serialized, .enabled(if: live, "LIVE=1 runs the live test against the installed app"))
struct LiveTests {
  @Test(.timeLimit(.minutes(5)))
  func operatesTheFixtureInTheBackground() throws {
    let fixture = try Fixture()
    let server = try LiveServer()
    try requireFixtureOnList(server)
    let state = parseLine(textOf(try server.call("list_apps", app: nil))) ?? [:]
    try #require(state["screen_locked"] as? Bool != true, "The screen is locked: unlock it to run the live test.")
    let frontBefore = try frontApp()
    var findings: [String] = []
    defer { print("Delivery findings:\n" + findings.joined(separator: "\n")) }

    // Reads the window of an app on the list, and numbers stay the same across reads.
    let first = try server.read()
    #expect(first.contains("app=\"\(fixtureName)\""))
    #expect(first.contains("Press Me"))
    #expect(try number(of: "Press Me", in: first) == number(of: "Press Me", in: try server.read()))

    // press works in the background and reports the change.
    let pressed = parseLine(textOf(try server.call("press", ["element": try number(of: "Press Me", in: first)]))) ?? [:]
    _ = try until { fixture.events("press").count == 1 ? true : nil }
    #expect(pressed["delivery"] as? String == "accessibility")
    #expect((pressed["state"] as? Object)?["changed"] as? Bool == true)
    #expect(fixture.events("press")[0]["active"] as? Bool == false)
    #expect(try frontApp() == frontBefore)

    // set_value reaches a text field and a slider, and refuses what is not a number for the slider.
    _ = try server.call("set_value", ["element": try number(of: #"placeholder="Plain""#, in: try server.read()), "value": "hello"])
    #expect(try server.read().contains(#"value="hello""#))
    let slider = try number(of: #"^\s*\d+ Slider"#, in: try server.read())
    _ = try server.call("set_value", ["element": slider, "value": "75"])
    #expect(try server.read().range(of: #"Slider[^\n]*value="75"#, options: .regularExpression) != nil)
    #expect(try server.call("set_value", ["element": slider, "value": "abc"])["isError"] as? Bool == true)
    #expect(try server.read().range(of: #"Slider[^\n]*value="75"#, options: .regularExpression) != nil)

    // A secure field's value is never shown.
    _ = try server.call("set_value", ["element": try number(of: #"placeholder="Secret""#, in: try server.read()), "value": "hunter2"])
    let afterSecret = try server.read()
    #expect(afterSecret.contains(#"placeholder="Secret""#) || afterSecret.contains("secure"))
    #expect(!afterSecret.contains("hunter2"))

    // type_text with an element reaches that element, not the focused one.
    let otherTextBefore = fixture.events("other_text").count
    _ = try server.call("type_text", ["element": try number(of: #"placeholder="Plain""#, in: try server.read()), "text": "typed"])
    Thread.sleep(forTimeInterval: 0.2)
    #expect(try server.read().range(of: #"value="[^"]*typed"#, options: .regularExpression) != nil)
    #expect(fixture.events("other_text").count == otherTextBefore)

    // type_text reaches an empty field in the background, in a second window.
    let other = try server.read(["window": 1])
    #expect(other.contains(#"placeholder="Other""#))
    let typed = parseLine(textOf(try server.call("type_text", ["element": try number(of: #"placeholder="Other""#, in: other), "text": "first"]))) ?? [:]
    #expect(typed["verified"] as? Bool == true)
    #expect(try server.read(["window": 1]).contains(#"value="first""#))
    _ = try server.read(["window": 0])

    // Line breaks: refused in a one-line field, and without an element.
    #expect(try server.call("type_text", ["element": try number(of: #"placeholder="Plain""#, in: try server.read(["window": 0])), "text": "a\nb"])["isError"] as? Bool == true)
    let unplaced = try server.call("type_text", ["text": "a\nb"])
    #expect(unplaced["isError"] as? Bool == true)
    #expect(textOf(unplaced).contains("press_key"))

    // A sheet is flagged and can be closed.
    _ = try server.call("press", ["element": try number(of: "Open Sheet", in: try server.read(["window": 0]))])
    _ = try until { fixture.events("sheet_opened").count == 1 ? true : nil }
    let open = try server.read(["window": 0])
    #expect(open.split(separator: "\n")[0].contains("modal=sheet"))
    _ = try server.call("press", ["element": try number(of: "Close Sheet", in: open)])
    _ = try until { fixture.events("sheet_closed").count == 1 ? true : nil }
    Thread.sleep(forTimeInterval: 0.5)
    #expect(try frontApp() == frontBefore)

    // A blocking modal reports an unknown outcome instead of a failure to retry.
    let modal = try server.call("press", ["element": try number(of: "Open Modal", in: try server.read(["window": 0]))])
    _ = try until { fixture.events("modal_opened").count == 1 ? true : nil }
    findings.append("Blocking modal press replied: \(textOf(modal).prefix(120))")
    #expect(!textOf(modal).contains("action_failed"))
    let listed = parseLine(textOf(try server.call("list_apps", app: nil)))?["apps"] as? [Object] ?? []
    #expect(listed.contains { $0["bundle_id"] as? String == fixtureBundleId })
    // A read that fails is reported through the findings below.
    let afterModal = (try? server.read(["window": 0])) ?? ""
    if let close = afterModal.split(separator: "\n").first(where: { $0.contains("Close Modal") }) {
      _ = try server.call("press", ["element": Int(close.trimmingCharacters(in: .whitespaces).split(separator: " ")[0])!])
    } else {
      _ = try server.call("press_key", ["key": "return"])
    }
    // The timeout is the finding.
    if (try? until(timeout: 8) { fixture.events("modal_closed").count == 1 ? true : nil }) == nil { findings.append("Could not close the modal in the background.") }
    Thread.sleep(forTimeInterval: 0.5)
    #expect(try frontApp() == frontBefore)

    // A screenshot's size matches window coordinates.
    let shot = try server.call("screenshot", ["window": 0])
    if shot["isError"] as? Bool == true {
      findings.append("Screenshot: \(textOf(shot))")
      #expect(textOf(shot).contains("Screen Recording"))
    } else {
      let content = shot["content"] as? [Object] ?? []
      let details = parseLine(content.last?["text"] as? String ?? "") ?? [:]
      #expect(content.first?["type"] as? String == "image")
      #expect((details["width"] as? Int ?? 0) >= 300 && (details["height"] as? Int ?? 0) >= 300)
    }

    // click_at reaches a view without accessibility, press_key follows it there, and the front app stays in front.
    _ = try server.call("press_key", ["key": "a"])
    Thread.sleep(forTimeInterval: 0.3)
    #expect(fixture.events("raw_key").isEmpty)
    let point = (fixture.events("ready")[0]["detail"] as? String ?? "0,0").split(separator: ",").compactMap { Double($0) }
    _ = try server.call("click_at", ["x": point[0], "y": point[1], "window": 0])
    _ = try until { fixture.events("raw_click").count == 1 ? true : nil }
    _ = try server.call("press_key", ["key": "b"])
    _ = try until { fixture.events("raw_key").count == 1 ? true : nil }
    #expect(fixture.events("raw_key")[0]["active"] as? Bool == false)
    findings.append("Fixture active at: \(fixture.events().filter { $0["active"] as? Bool == true }.map { $0["event"] as? String ?? "" }.joined(separator: " "))")
    if let area = try server.read(["window": 0]).split(separator: "\n").first(where: { $0.contains("ScrollArea") }) {
      let scrolled = try server.call("scroll", ["element": Int(area.trimmingCharacters(in: .whitespaces).split(separator: " ")[0])!, "direction": "down"])
      findings.append("scroll: \(textOf(scrolled).prefix(80))")
    }
    #expect(try frontApp() == frontBefore)

    // The point outside a window is refused.
    let outside = try server.call("click_at", ["x": 100000, "y": 1])
    #expect(outside["isError"] as? Bool == true)
    #expect(textOf(outside).contains("out_of_window"))
  }
}
