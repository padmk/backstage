import Darwin

struct ProcessStart: Equatable {
  let seconds: UInt64
  let microseconds: UInt64
}

// LaunchServices can return no NSRunningApplication for a live pid, as observed for Finder under test load.
// The kernel's start time identifies the process independently of LaunchServices and changes on pid reuse.
func processStart(of pid: pid_t) -> ProcessStart? {
  guard pid > 0 else { return nil }
  var info = proc_bsdinfo()
  let size = Int32(MemoryLayout<proc_bsdinfo>.size)
  guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != SZOMB else { return nil }
  return ProcessStart(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
}

func requireSameProcess(_ app: AppIdentity) throws {
  guard let expected = app.processStart, processStart(of: app.pid) == expected else {
    throw HelperError(code: "app_changed", message: "\(app.name) stopped while waiting. Try again.")
  }
}
