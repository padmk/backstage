// Measures the real command and the installed app against the fixture app, with BENCH=1 (and BENCH_ROUNDS, 30 by
// default). It needs the app installed with Accessibility and the fixture app on the list, as the live test does.

import Foundation
import Testing

private let bench = ProcessInfo.processInfo.environment["BENCH"] == "1"

@Suite(.serialized, .enabled(if: bench, "BENCH=1 measures latency against the installed app"))
struct BenchTests {
  @Test(.timeLimit(.minutes(10)))
  func latency() throws {
    let rounds = Int(ProcessInfo.processInfo.environment["BENCH_ROUNDS"] ?? "") ?? 30
    try #require(rounds >= 1, "BENCH_ROUNDS must be a whole number of at least 1")
    let fixture = try Fixture()
    let server = try LiveServer()
    try requireFixtureOnList(server)

    // A refusal answers in milliseconds, so a round that failed stops the run rather than count as a timing.
    func call(_ name: String, _ arguments: Object = [:], app: String? = fixtureBundleId) throws {
      let result = try server.call(name, arguments, app: app)
      if result["isError"] as? Bool == true { throw TestFailure("\(name) failed: \(textOf(result))") }
    }
    func measure(_ label: String, _ action: () throws -> Void) throws {
      var times: [Double] = []
      for _ in 0..<rounds {
        let started = Date()
        try action()
        times.append(Date().timeIntervalSince(started) * 1000)
      }
      times.sort()
      let at = { (share: Double) in String(format: "%8.1f", times[Int(Double(times.count - 1) * share)]) }
      print("\(label.padding(toLength: 26, withPad: " ", startingAt: 0))\(at(0.5)) ms p50\(at(0.95)) ms p95")
    }

    let started = Date()
    let tree = textOf(try server.call("get_window_state", ["window": 0]))
    print("\("first read".padding(toLength: 26, withPad: " ", startingAt: 0))\(String(format: "%8.1f", Date().timeIntervalSince(started) * 1000)) ms")
    let press = try number(of: "Press Me", in: tree)
    try measure("list_apps") { try call("list_apps", app: nil) }
    try measure("get_window_state") { try call("get_window_state", ["window": 0]) }
    try measure("press with state report") { try call("press", ["element": press]) }
    try measure("screenshot") { try call("screenshot", ["window": 0]) }
    withExtendedLifetime(fixture) {}
  }
}
