// The names another of the user's Macs goes by in `computer`: what `ssh` reaches it under, checked the same way by
// the command, which runs ssh, and by the app, which keeps the list of Macs agents may reach.

import Foundation

public enum ComputerName {
  public static let maxLength = 253

  // Host names and ssh_config aliases, never something ssh could read as an option or a user.
  public static func problem(with name: String) -> String? {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
    guard name.count <= maxLength, let first = name.unicodeScalars.first, first.isASCII, CharacterSet.alphanumerics.contains(first),
      name.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) })
    else { return "computer must be a host name or an alias from ~/.ssh/config, such as mbp" }
    return nil
  }
}
