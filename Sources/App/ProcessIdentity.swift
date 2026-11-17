import AppKit
import Darwin

struct ProcessStart: Equatable {
  let seconds: UInt64
  let microseconds: UInt64
}

enum ProcessState: Equatable {
  case running(ProcessStart)
  case exited
  // The kernel did not say, for example a process of another user (EPERM).
  case unreadable
}

// LaunchServices can return no NSRunningApplication for a live pid, as observed for Finder under test load.
// The kernel's start time identifies the process independently of LaunchServices and changes on pid reuse.
// Observed on macOS 26: proc_pidinfo fails with ESRCH for a pid without a process, and EPERM for one of root's.
func processState(of pid: pid_t) -> ProcessState {
  guard pid > 0 else { return .unreadable }
  var info = proc_bsdinfo()
  let size = Int32(MemoryLayout<proc_bsdinfo>.size)
  errno = 0
  guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return errno == ESRCH ? .exited : .unreadable }
  if info.pbi_status == SZOMB { return .exited }
  return .running(ProcessStart(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec))
}

func processStart(of pid: pid_t) -> ProcessStart? {
  if case .running(let start) = processState(of: pid) { return start }
  return nil
}

// The executable the kernel runs for a pid, with links resolved.
func executablePath(of pid: pid_t) -> String? {
  var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
  let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
  guard length > 0 else { return nil }
  let path = String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

// The start time of the process LaunchServices describes, or nil when the pid runs another executable or changed
// hands while it was read. The start time is read on both sides of the executable, so a pid that passes to another
// process in between never pairs one process's bundle id with the other's start time. On this Mac the kernel's
// executable equals LaunchServices' executableURL for every app with a bundle.
func processStart(of app: NSRunningApplication) -> ProcessStart? {
  processStart(of: app.processIdentifier, running: app.executableURL?.resolvingSymlinksInPath().path)
}

func processStart(of pid: pid_t, running executable: String?) -> ProcessStart? {
  guard let executable, let before = processStart(of: pid), executablePath(of: pid) == executable,
    processStart(of: pid) == before
  else { return nil }
  return before
}

func requireSameProcess(_ app: AppIdentity) throws {
  guard let expected = app.processStart, processStart(of: app.pid) == expected else {
    throw HelperError(code: "app_changed", message: "\(app.name) stopped while waiting. Try again.")
  }
}

// The app's AppKit handle, for what only AppKit delivers (hiding, quitting, coming forward), or nil once the kernel
// shows the process has exited or the pid belongs to another process. The handle is taken first and the kernel asked
// after, so a handle is returned only for the process that still holds the pid. A live process LaunchServices gives
// no handle for, and a process the kernel does not describe, are no exit: both fail before any effect.
func runningApplication(_ app: AppIdentity) throws -> NSRunningApplication? {
  let current = onMain { NSRunningApplication(processIdentifier: app.pid) }
  guard let expected = app.processStart else { throw unreachable(app) }
  switch processState(of: app.pid) {
  case .exited: return nil
  case .running(let start) where start != expected: return nil
  case .unreadable: throw unreachable(app)
  case .running:
    guard let current, !current.isTerminated, current.bundleIdentifier == app.bundleId else { throw unreachable(app) }
    return current
  }
}

private func unreachable(_ app: AppIdentity) -> HelperError {
  HelperError(code: "action_failed", message: "macOS does not show \(app.name) as running at the moment, so nothing was done. Try again.")
}
