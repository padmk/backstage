// Who is asking, as the approval window shows it: the agent's name and the icon of the app it runs in.

import AppKit

private let maxAncestors = 12

// The first app with a Dock icon above the process on the other end of the socket, such as the terminal or editor
// the agent runs in. It comes from the process tree, not from the name the client sends, which any client could
// claim; the name stays a description, not proof.
func requesterIcon(peer: pid_t?) -> NSImage? {
  var pid = peer
  for _ in 0..<maxAncestors {
    guard let current = pid, current > 1 else { return nil }
    if let app = onMain({ NSRunningApplication(processIdentifier: current) }), app.activationPolicy == .regular, let url = app.bundleURL {
      return onMain { NSWorkspace.shared.icon(forFile: url.path) }
    }
    pid = parent(of: current)
  }
  return nil
}

private func parent(of pid: pid_t) -> pid_t? {
  var info = proc_bsdinfo()
  let size = Int32(MemoryLayout<proc_bsdinfo>.size)
  guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
  return pid_t(info.pbi_ppid)
}

// The process on the other end of a Unix socket.
func peerProcess(of descriptor: Int32) -> pid_t? {
  var pid = pid_t(0)
  var length = socklen_t(MemoryLayout<pid_t>.size)
  guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
  return pid
}
