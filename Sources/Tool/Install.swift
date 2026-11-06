// Installs the app into /Applications and signs it for this Mac. macOS ties permissions to the signature's
// designated requirement, so the installed copy is signed with a certificate of this Mac that stays the same:
// grants survive updates without a paid Developer ID. A build arrives signed ad hoc and is signed again here.

import Darwin
import Foundation
import HelperLink

private let lockStale: TimeInterval = 5
private let lockTimeout: TimeInterval = 200

struct Installer {
  let directories: Directories

  private var signingKeychain: String { directories.data + "/signing.keychain-db" }
  private var signingHashFile: String { directories.data + "/signing.identity" }
  private var signingChangedFile: String { directories.data + "/signing.changed" }

  // MARK: Checks

  func isOurApp(_ app: String) -> Bool {
    (NSDictionary(contentsOfFile: app + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String) == Product.bundleIdentifier
  }

  private var certificateHash: String? {
    guard let text = try? String(contentsOfFile: signingHashFile, encoding: .utf8) else { return nil }
    let hash = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return hash.range(of: "^[0-9A-F]{40}$", options: .regularExpression) != nil ? hash : nil
  }

  // Signed with this Mac's own certificate. The build identity alone is public, so a bundle someone else put in
  // the app's place could match it.
  func isSignedHere(_ app: String) -> Bool {
    guard let hash = certificateHash else { return false }
    return (try? runProcess("/usr/bin/codesign", ["--verify", "--strict", "-R=certificate leaf = H\"\(hash)\"", app])) != nil
  }

  // The installed app is this build, the command in it too, and it is signed here.
  func installedMatches(_ source: String) -> Bool {
    let installed = Product.installedAppPath
    guard isOurApp(installed) else { return false }
    for part in ["Contents/MacOS/" + Product.appExecutableName, Product.commandRelativePath] {
      guard let wanted = buildIdentity(ofExecutableAt: source + "/" + part), buildIdentity(ofExecutableAt: installed + "/" + part) == wanted else { return false }
    }
    return isSignedHere(installed)
  }

  // MARK: Installing

  // Copies `source` next to the installed app, signs the copy and swaps it in, in one step that leaves either the
  // old app or the new one in place. Returns whether anything changed.
  func install(from source: String) throws -> Bool {
    try ensurePrivateDirectory(directories.data)
    return try withSetupLock {
      if source == Product.installedAppPath ? isSignedHere(source) : installedMatches(source) { return false }
      let target = installTarget()
      let folder = (target as NSString).deletingLastPathComponent
      let staging = "\(folder)/.\(Product.appName).app.incoming-\(getpid())"
      try? FileManager.default.removeItem(atPath: staging)
      defer { try? FileManager.default.removeItem(atPath: staging) }
      do {
        try runProcess("/usr/bin/ditto", [source, staging])
      } catch let failure as HelperFailure {
        throw HelperFailure(code: nil, message: "Cannot install into \(folder): \(failure.message). Run this from an administrator account.")
      }
      try sign(staging)
      if FileManager.default.fileExists(atPath: target) {
        guard isOurApp(target) else {
          throw HelperFailure(code: nil, message: "\(target) is another app, not \(Product.appName). Move it elsewhere, then run setup again.")
        }
        // The old app ends up at `staging`, which the deferred removal clears.
        guard renamex_np(staging, target, UInt32(RENAME_SWAP)) == 0 else { throw installFailure(folder) }
      } else {
        guard rename(staging, target) == 0 else { throw installFailure(folder) }
      }
      return true
    }
  }

  // Where the app already is, else /Applications, else ~/Applications for an account that cannot write there.
  func installTarget() -> String {
    if let existing = Product.appLocations.first(where: { FileManager.default.fileExists(atPath: $0) }) { return existing }
    let system = Product.appLocations[0], user = Product.appLocations[1]
    if FileManager.default.isWritableFile(atPath: (system as NSString).deletingLastPathComponent) { return system }
    try? FileManager.default.createDirectory(atPath: (user as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    return user
  }

  private func installFailure(_ folder: String) -> HelperFailure {
    let reason = String(cString: strerror(errno))
    let advice = errno == EACCES || errno == EPERM ? " Run this from an administrator account." : ""
    return HelperFailure(code: nil, message: "Cannot install into \(folder): \(reason).\(advice)")
  }

  // The command inside first, then the bundle that seals it.
  private func sign(_ app: String) throws {
    let signing = try signingArguments()
    try runProcess("/usr/bin/codesign", ["--force"] + signing + ["--identifier", Product.bundleIdentifier + ".command", app + "/" + Product.commandRelativePath])
    try runProcess("/usr/bin/codesign", ["--force"] + signing + ["--identifier", Product.bundleIdentifier, app])
    try runProcess("/usr/bin/codesign", ["--verify", "--strict", app])
    guard isSignedHere(app) else { throw HelperFailure(code: nil, message: "The signed copy does not verify against this Mac's certificate.") }
  }

  // MARK: The signing identity

  // Only a missing identity creates a new one. Any other failure stops, because replacing the identity or signing
  // ad hoc would end the permissions.
  private func signingArguments() throws -> [String] {
    let exists = FileManager.default.fileExists(atPath: signingHashFile) && FileManager.default.fileExists(atPath: signingKeychain)
    if !exists { try createSigningIdentity() }
    guard let hash = certificateHash else { throw HelperFailure(code: nil, message: "\(signingHashFile) does not hold a certificate hash.") }
    chmod(signingKeychain, 0o600)
    try runProcess("/usr/bin/security", ["unlock-keychain", "-p", "", signingKeychain])
    return ["--sign", hash, "--keychain", signingKeychain]
  }

  // The keychain exists only for this and has an empty password: its protection is the private directory it lies in.
  private func createSigningIdentity() throws {
    let temporary = directories.data + "/signing-\(getpid())-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: temporary) }
    let config = temporary + "/c.cnf", key = temporary + "/k.pem", certificate = temporary + "/c.pem", bundle = temporary + "/i.p12"
    try """
    [req]
    distinguished_name=dn
    x509_extensions=ext
    prompt=no
    [dn]
    CN=\(Product.appName) local signing
    [ext]
    basicConstraints=critical,CA:false
    keyUsage=critical,digitalSignature
    extendedKeyUsage=critical,codeSigning

    """.write(toFile: config, atomically: true, encoding: .utf8)
    try runProcess("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "36500", "-config", config, "-keyout", key, "-out", certificate])
    try runProcess("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key, "-in", certificate, "-out", bundle, "-passout", "pass:local"])
    try? FileManager.default.removeItem(atPath: signingKeychain)
    try runProcess("/usr/bin/security", ["create-keychain", "-p", "", signingKeychain])
    try runProcess("/usr/bin/security", ["set-keychain-settings", signingKeychain])
    try runProcess("/usr/bin/security", ["unlock-keychain", "-p", "", signingKeychain])
    try runProcess("/usr/bin/security", ["import", bundle, "-k", signingKeychain, "-P", "local", "-T", "/usr/bin/codesign"])
    try runProcess("/usr/bin/security", ["set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", "", signingKeychain])
    let fingerprint = try runProcess("/usr/bin/openssl", ["x509", "-in", certificate, "-noout", "-fingerprint", "-sha1"]).output
    let hash = (fingerprint.split(separator: "=").last.map(String.init) ?? "").replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    try hash.write(toFile: signingHashFile, atomically: true, encoding: .utf8)
    chmod(signingHashFile, 0o600)
    FileManager.default.createFile(atPath: signingChangedFile, contents: Data())
  }

  // Tells setup, once, that permission entries for an earlier signature no longer apply.
  func takeSigningChange() -> Bool {
    guard FileManager.default.fileExists(atPath: signingChangedFile) else { return false }
    try? FileManager.default.removeItem(atPath: signingChangedFile)
    return true
  }

  // MARK: One setup at a time

  // A setup killed midway leaves its lock behind, so a lock whose owner is gone is free.
  private func withSetupLock<T>(_ action: () throws -> T) throws -> T {
    let lock = directories.data + "/setup.lock"
    let started = Date()
    while mkdir(lock, 0o700) != 0 {
      if lockIsAbandoned(lock) {
        try? FileManager.default.removeItem(atPath: lock)
        continue
      }
      if Date().timeIntervalSince(started) > lockTimeout { throw HelperFailure(code: nil, message: "\(lock) is held by a running setup.") }
      Thread.sleep(forTimeInterval: 0.2)
    }
    try? String(getpid()).write(toFile: lock + "/owner", atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: lock) }
    return try action()
  }

  private func lockIsAbandoned(_ lock: String) -> Bool {
    if let text = try? String(contentsOfFile: lock + "/owner", encoding: .utf8), let owner = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), owner > 0 {
      return kill(owner, 0) != 0 && errno == ESRCH
    }
    // No owner yet: the lock is either just taken or left from a crash at that very moment.
    guard let modified = (try? FileManager.default.attributesOfItem(atPath: lock))?[.modificationDate] as? Date else { return false }
    return Date().timeIntervalSince(modified) > lockStale
  }
}

// Why this Mac cannot run the app, or nil when it can.
func platformProblem() -> String? {
  var machine = utsname()
  uname(&machine)
  let architecture = withUnsafeBytes(of: &machine.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
  if architecture != "arm64" { return "\(Product.appName) needs a Mac with Apple silicon" }
  let version = ProcessInfo.processInfo.operatingSystemVersion
  if version.majorVersion < Product.minimumMacOS {
    return "\(Product.appName) needs macOS \(Product.minimumMacOS) or newer; this Mac has \(version.majorVersion).\(version.minorVersion)"
  }
  return nil
}
