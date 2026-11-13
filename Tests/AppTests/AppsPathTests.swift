// The rule for which files operations may touch, on a home folder made in a temporary folder.

@testable import App
import Foundation
import Testing

// A home with a Library holding app data and iCloud Drive, a document, and links out of it and into Library.
private final class Home {
  let folder: TemporaryFolder
  let path: String

  init() throws {
    folder = try TemporaryFolder()
    path = folder.path + "/Home"
    try folder.file("Home/Library/Messages/chat.db")
    try folder.file("Home/Library/Mobile Documents/com~apple~CloudDocs/notes.txt")
    try folder.file("Home/Documents/report.txt")
    try folder.folder("Home/Documents/Folder")
    try folder.link("Home/ToEtc", to: "/etc")
    try folder.link("Home/ToHosts", to: "/etc/hosts")
    try folder.link("Home/ToLibrary", to: path + "/Library")
  }

  func user(_ relative: String, mustExist: Bool = true, followingLink: Bool = false) throws -> URL {
    try userPath(["path": path + relative], mustExist: mustExist, followingLink: followingLink, home: path)
  }
}

@Suite struct PathRuleTests {
  @Test func libraryIsRefusedWhateverTheCaseItIsWrittenIn() throws {
    let home = try Home()
    try #require(FileManager.default.fileExists(atPath: home.path + "/LIBRARY"), "the temporary folder's volume ignores case")
    for relative in ["/Library", "/LIBRARY", "/library", "/LIBRARY/Messages/chat.db", "/library/messages", "/LiBrArY/"] {
      for followingLink in [false, true] {
        helperError("not_allowed") { try home.user(relative, followingLink: followingLink) }
      }
      helperError("not_allowed") { try openableFile(home.path + relative, home: home.path) }
      #expect(reportablePath(home.path + relative, home: home.path) == nil, "\(relative)")
    }
    helperError("not_allowed") { try home.user("/LIBRARY/new.pdf", mustExist: false) }
  }

  @Test func iCloudDriveInLibraryIsReachable() throws {
    let home = try Home()
    let file = "/Library/Mobile Documents/com~apple~CloudDocs/notes.txt"
    #expect(try home.user(file).path == home.path + file)
    #expect(try openableFile(home.path + file, home: home.path).path == home.path + file)
    #expect(reportablePath(home.path + file, home: home.path) == home.path + file)
  }

  @Test func filesInTheHomeFolderAreReachableUnderTheirOwnNames() throws {
    let home = try Home()
    #expect(try home.user("/Documents/report.txt").path == home.path + "/Documents/report.txt")
    #expect(try home.user("/DOCUMENTS/REPORT.TXT").path == home.path + "/Documents/report.txt")
    #expect(try home.user("/Documents/new.pdf", mustExist: false).path == home.path + "/Documents/new.pdf")
    helperError("not_found") { try home.user("/Documents/missing.txt") }
    #expect(try openableFile(home.path + "/Documents/report.txt", home: home.path).path == home.path + "/Documents/report.txt")
    helperError("not_found") { try openableFile(home.path + "/Documents/Folder", home: home.path) }
  }

  @Test func theHomeFolderItselfAndPathsOutsideItAreRefused() throws {
    let home = try Home()
    for relative in ["", "/", "/Documents/..", "/Documents/../../Home"] {
      helperError("not_allowed") { try home.user(relative) }
    }
    helperError("not_allowed") { try userPath(["path": "/etc/hosts"], home: home.path) }
    helperError("invalid_arguments") { try userPath(["path": "Documents/report.txt"], home: home.path) }
  }

  @Test func aLinkIsCheckedByWhereItLeadsOnlyWhenFollowed() throws {
    let home = try Home()
    #expect(try home.user("/ToEtc").path == home.path + "/ToEtc")
    helperError("not_allowed") { try home.user("/ToEtc", followingLink: true) }
    helperError("not_allowed") { try home.user("/ToEtc/hosts") }
    helperError("not_allowed") { try openableFile(home.path + "/ToHosts", home: home.path) }
    helperError("not_allowed") { try home.user("/ToLibrary/Messages/chat.db") }
    #expect(reportablePath(home.path + "/ToHosts", home: home.path) == nil)
  }

  @Test func aFolderTheHelperMayNotReadIsReportedAsAMissingPermission() throws {
    let home = try Home()
    try home.folder.file("Home/Locked/inner/secret.txt")
    let locked = home.path + "/Locked"
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
    // Restoring the permissions only lets the temporary folder be removed.
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
    let error = helperError("permission_missing") { try home.user("/Locked/inner/secret.txt") }
    #expect(error?.message.contains(locked + ".") == true)
    helperError("permission_missing") { try openableFile(locked + "/inner/secret.txt", home: home.path) }
  }

  @Test func otherVolumesRefuseCopiesOfLibraryAndBackups() {
    let home = "/Users/someone"
    for path in [
      "/Volumes/Data/Users/other/Library/Messages/chat.db", "/Volumes/Data/users/other/LIBRARY", "/Volumes/Data/Users/other/Library",
      "/Volumes/Backup/Backups.backupdb/Mac/Latest/Data/Users/other/Documents/a.txt", "/Volumes/.timemachine/Mac/2026-11-01.backup/a",
    ] {
      #expect(!isReachablePath(path, home: home), "\(path)")
    }
    for path in ["/Volumes/Stick/Users/other/Documents/a.txt", "/Volumes/Stick/Library Books/a.pdf", "/Volumes/Stick/a.txt"] {
      #expect(isReachablePath(path, home: home), "\(path)")
    }
  }

  // Pages and Numbers report a document's file as the app gives it; the rule above decides on it, in any letter case
  // and through links, and a place the app did not give is refused rather than taken for a document without a file.
  @Test func anOpenDocumentIsCheckedByTheSameRule() throws {
    let home = try Home()
    let check = { (value: Any?) in try reachableDocumentPath(value, home: home.path) }
    #expect(try check(home.path + "/Documents/report.txt") == home.path + "/Documents/report.txt")
    #expect(try check(home.path + "/Library/Mobile Documents/com~apple~CloudDocs/notes.txt") != "")
    #expect(try check("") == "")
    for path in [home.path + "/LIBRARY/Messages/chat.db", home.path + "/library/Messages", home.path + "/Library/Messages/chat.db",
                 home.path + "/ToLibrary/Messages/chat.db", "/tmp/budget.numbers", "/etc/hosts", "budget.numbers"] {
      helperError("not_allowed") { try check(path) }
    }
    helperError("action_failed") { try check(nil) }
    helperError("action_failed") { try check(NSNull()) }
  }
}
