// Reading a child process's output while it runs, as the app and the command both do.

import Foundation
import Synchronization

// Reads a file handle to its end on a thread of its own, so a child that writes more than a pipe holds never stalls.
// The data is handed over only once the read has ended: a caller that stops waiting earlier gets nil, never a part.
public final class PipeReader: Sendable {
  private let result = Mutex<Data?>(nil)
  private let ended = DispatchGroup()

  public init(_ handle: FileHandle) {
    ended.enter()
    DispatchQueue.global().async { [self] in
      let data = handle.readDataToEndOfFile()
      result.withLock { $0 = data }
      ended.leave()
    }
  }

  // Everything the handle gave, once it ended by the deadline; nil when it is still open, as when a process the
  // child started keeps the pipe after the child has exited.
  public func data(by deadline: DispatchTime = .distantFuture) -> Data? {
    guard ended.wait(timeout: deadline) == .success else { return nil }
    return result.withLock { $0 }
  }
}
