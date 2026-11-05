// The macOS grants that ready operations need. macOS asks for one when the user puts its app on the list, while
// they are at the keyboard; an operation never shows the prompt itself, so no task stops on a dialog no one sees.
// They are macOS's, not Backstage's: an app still needs to be on the list.

import AppKit
import CoreServices
import EventKit

enum GrantState: String {
  case granted, notAsked = "not_asked", denied
  // Automation can be read only while the target app runs.
  case unknown
}

struct AppGrant: Identifiable {
  enum Kind {
    case contacts, events(EKEntityType), automation(bundleId: String)
  }

  let id: String
  var name: String
  // The app's own name, for an app known in several versions, whose name otherwise carries the bundle id.
  var plainName: String? = nil
  let purpose: String
  let kind: Kind
  // The apps on the list whose operations use it, and which of their operations; nil means all of them.
  let listedApps: [String]
  var operations: Set<String>? = nil

  // The app whose icon shows next to the grant.
  var appBundleId: String {
    switch kind {
    case .contacts: "com.apple.AddressBook"
    case .events(let type): type == .reminder ? "com.apple.reminders" : "com.apple.iCal"
    case .automation(let bundleId): bundleId
    }
  }

  // The Privacy & Security pane where the user can change it.
  var pane: String {
    switch kind {
    case .contacts: "Privacy_Contacts"
    case .events(let type): type == .reminder ? "Privacy_Reminders" : "Privacy_Calendars"
    case .automation: "Privacy_Automation"
    }
  }
}

let appGrants: [AppGrant] = [
  AppGrant(id: "calendars", name: "Calendars", purpose: "Read and add events", kind: .events(.event), listedApps: ["com.apple.iCal"]),
  AppGrant(id: "reminders", name: "Reminders", purpose: "Read, add and complete reminders", kind: .events(.reminder), listedApps: ["com.apple.reminders"]),
  AppGrant(id: "contacts", name: "Contacts", purpose: "Find, read and add contacts", kind: .contacts, listedApps: ["com.apple.AddressBook"]),
  AppGrant(id: "notes", name: "Notes", purpose: "Find, read and create notes", kind: .automation(bundleId: "com.apple.Notes"), listedApps: ["com.apple.Notes"]),
  AppGrant(id: "mail", name: "Mail", purpose: "Read mail and save drafts", kind: .automation(bundleId: "com.apple.mail"), listedApps: ["com.apple.mail"]),
  AppGrant(id: "messages", name: "Messages", purpose: "List chats and send messages", kind: .automation(bundleId: "com.apple.MobileSMS"), listedApps: ["com.apple.MobileSMS"],
           operations: ["list_chats", "send"]),
  // Tags and the Trash of a symbolic link go through the file system, not Finder.
  AppGrant(id: "finder", name: "Finder", purpose: "Selection, reveal and Trash", kind: .automation(bundleId: "com.apple.finder"), listedApps: ["com.apple.finder"],
           operations: ["selection", "front_folder", "reveal", "trash"]),
] + scriptedGrants("pages", purpose: "Open, read and export documents", of: pagesKnowledge)
  + scriptedGrants("numbers", purpose: "Read and change spreadsheets", of: numbersKnowledge) + [
  AppGrant(id: "music", name: "Music", purpose: "Control playback", kind: .automation(bundleId: "com.apple.Music"), listedApps: ["com.apple.Music"]),
  // Only the appearance operations of System Settings script System Events; the volume uses no other app.
  AppGrant(id: "system-events", name: "System Events", purpose: "Switch dark and light appearance", kind: .automation(bundleId: "com.apple.systemevents"),
           listedApps: ["com.apple.systempreferences"], operations: ["get_appearance", "set_appearance"]),
]

// One grant for each version the app definition knows, since macOS grants Automation per bundle id and each can
// be on the list. Whether a version is installed is checked when the grants are shown, not here.
private func scriptedGrants(_ id: String, purpose: String, of app: AppKnowledge) -> [AppGrant] {
  let several = app.bundleIds.count > 1
  return app.bundleIds.map { bundleId in
    AppGrant(id: several ? "\(id)-\(bundleId)" : id, name: several ? "\(app.name) (\(bundleId))" : app.name,
             plainName: several ? app.name : nil, purpose: purpose, kind: .automation(bundleId: bundleId), listedApps: [bundleId])
  }
}

// The grants that matter for the apps on the list: those of every installed app while every app is allowed.
// A version's bundle id shows only while another version of the same app shows too.
func appGrants(forListed bundleIds: Set<String>, everyApp: Bool) -> [AppGrant] {
  let shown = everyApp
    ? appGrants.filter { grant in grant.listedApps.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil } }
    : appGrants.filter { !bundleIds.isDisjoint(with: $0.listedApps) }
  return shown.map { grant in
    guard let plain = grant.plainName, shown.filter({ $0.plainName == plain }).count == 1 else { return grant }
    var single = grant
    single.name = plain
    return single
  }
}

// Before an operation runs: a missing Automation grant fails at once with what to do, instead of a prompt
// mid-task. macOS can tell only for a running app, so a target that is not running, such as System Events for
// the appearance operations, starts hidden first; when macOS still cannot tell, the operation does not run.
func requireAutomation(for operation: String, of appBundleId: String) throws {
  guard let grant = appGrants.first(where: { $0.listedApps.contains(appBundleId) && ($0.operations?.contains(operation) ?? true) }),
    case .automation(let target) = grant.kind
  else { return }
  var state = automationState(target, ask: false)
  if state == .unknown, let url = onMain({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) }) {
    _ = try startAppHidden(at: url.path, name: grant.name)
    state = automationState(target, ask: false)
  }
  switch state {
  case .granted: return
  case .notAsked: throw grantMissing(grant.name)
  case .denied: throw grantDenied(grant.name)
  case .unknown:
    throw HelperError(code: "permission_missing", message: "macOS could not tell whether Backstage may use \(grant.name), so the operation did not run. Ask the user to check it in Backstage, on the Setup tab, under App access.")
  }
}

func grantMissing(_ name: String) -> HelperError {
  HelperError(code: "permission_missing", message: "macOS has not been asked yet whether Backstage may use \(name). Ask the user to allow it in Backstage, on the Setup tab, under App access. Backstage does not show that prompt during a task.")
}

func grantDenied(_ name: String) -> HelperError {
  HelperError(code: "access_denied", message: "macOS does not let Backstage use \(name). The user can turn it on in System Settings > Privacy & Security, or Backstage's Setup tab links there.")
}

func grantState(_ grant: AppGrant) -> GrantState {
  switch grant.kind {
  case .contacts: return contactsAccessState()
  case .events(let type): return eventAccessState(type)
  case .automation(let bundleId): return automationState(bundleId, ask: false)
  }
}

// Shows macOS's prompt for a grant it has not asked about. Blocks until the user answers, so it runs off the main thread.
func requestGrant(_ grant: AppGrant) {
  switch grant.kind {
  case .contacts: requestContactsAccess()
  case .events(let type): requestEventAccess(type)
  case .automation(let bundleId):
    // macOS asks only about a running app, so one that is not running starts hidden, behind the user's work.
    if automationState(bundleId, ask: false) == .unknown,
      let url = onMain({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) }) {
      _ = try? startAppHidden(at: url.path, name: grant.name)
    }
    _ = automationState(bundleId, ask: true)
  }
}

func automationState(_ bundleId: String, ask: Bool) -> GrantState {
  var target = AEAddressDesc()
  let identifier = Array(bundleId.utf8)
  guard AECreateDesc(typeApplicationBundleID, identifier, identifier.count, &target) == noErr else { return .unknown }
  defer { AEDisposeDesc(&target) }
  switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask) {
  case noErr: return .granted
  case OSStatus(errAEEventNotPermitted): return .denied
  case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
  default: return .unknown
  }
}
