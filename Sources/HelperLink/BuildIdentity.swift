// Which build an executable is, so the command and the app it talks to can tell when one of them was replaced.
// It is the linker's UUID (LC_UUID), which follows the code and not the signature: signing a copy for this Mac
// does not change it, and any change to the code does. A running process reads it once, so a later setup that
// replaces the file does not change what that process reports.

import Foundation
import MachO

private let loadCommandUUID: UInt32 = 0x1B

// The UUID of a thin 64-bit Mach-O file, or nil when the file is missing or is not one.
public func buildIdentity(ofExecutableAt path: String) -> String? {
  guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
  // Closing a handle that was only read from loses nothing.
  defer { try? handle.close() }
  // A file that cannot be read has no identity, as the comment above says.
  guard let header = try? handle.read(upToCount: MemoryLayout<mach_header_64>.size), header.count == MemoryLayout<mach_header_64>.size else { return nil }
  let magic = header.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
  guard magic == MH_MAGIC_64 else { return nil }
  let commandCount = header.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
  let commandsSize = header.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }
  // A file that cannot be read has no identity, as the comment above says.
  guard commandsSize < 1 << 20, let commands = try? handle.read(upToCount: Int(commandsSize)), commands.count == Int(commandsSize) else { return nil }
  var offset = 0
  for _ in 0..<commandCount {
    guard offset + 8 <= commands.count else { return nil }
    let (command, size) = commands.withUnsafeBytes { bytes in
      (bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self), Int(bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)))
    }
    guard size >= 8, offset + size <= commands.count else { return nil }
    if command == loadCommandUUID, size >= 24 {
      return commands[(commands.startIndex + offset + 8)..<(commands.startIndex + offset + 24)].map { String(format: "%02x", $0) }.joined()
    }
    offset += size
  }
  return nil
}

// The running executable's identity, read from its image in memory, so it is the code that runs even when a setup
// has since replaced the file.
public let ownBuildIdentity: String = {
  guard let header = _dyld_get_image_header(0) else { return "unknown" }
  return header.withMemoryRebound(to: mach_header_64.self, capacity: 1) { image -> String in
    var command = UnsafeRawPointer(image).advanced(by: MemoryLayout<mach_header_64>.size)
    for _ in 0..<image.pointee.ncmds {
      let load = command.load(as: load_command.self)
      if load.cmd == loadCommandUUID {
        return (0..<16).map { String(format: "%02x", command.load(fromByteOffset: 8 + $0, as: UInt8.self)) }.joined()
      }
      command = command.advanced(by: Int(load.cmdsize))
    }
    return "unknown"
  }
}()
