// The macOS grants that operations need, so the user can give them all at once instead of meeting each prompt
// in the middle of a task. They are macOS's, not Backstage's: each app still needs a Backstage approval.

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
  let name: String
  let purpose: String
  let kind: Kind

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
  AppGrant(id: "calendars", name: "Calendars", purpose: "Calendar operations", kind: .events(.event)),
  AppGrant(id: "reminders", name: "Reminders", purpose: "Reminders operations", kind: .events(.reminder)),
  AppGrant(id: "contacts", name: "Contacts", purpose: "Contacts operations", kind: .contacts),
  AppGrant(id: "notes", name: "Notes", purpose: "Control Notes through scripting", kind: .automation(bundleId: "com.apple.Notes")),
  AppGrant(id: "mail", name: "Mail", purpose: "Control Mail through scripting", kind: .automation(bundleId: "com.apple.mail")),
  AppGrant(id: "messages", name: "Messages", purpose: "Send messages through scripting", kind: .automation(bundleId: "com.apple.MobileSMS")),
  AppGrant(id: "finder", name: "Finder", purpose: "Selection, reveal and Trash", kind: .automation(bundleId: "com.apple.finder")),
  AppGrant(id: "pages", name: "Pages", purpose: "Documents through scripting", kind: .automation(bundleId: installedBundleId(pagesKnowledge) ?? pagesKnowledge.bundleId)),
  AppGrant(id: "numbers", name: "Numbers", purpose: "Spreadsheets through scripting", kind: .automation(bundleId: installedBundleId(numbersKnowledge) ?? numbersKnowledge.bundleId)),
  AppGrant(id: "music", name: "Music", purpose: "Control Music through scripting", kind: .automation(bundleId: "com.apple.Music")),
  AppGrant(id: "system-events", name: "System Events", purpose: "Appearance in System Settings", kind: .automation(bundleId: "com.apple.systemevents")),
]

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
    // macOS asks only about a running app; an Apple event starts it in the background when it is not.
    if automationState(bundleId, ask: false) == .unknown {
      _ = try? runScript("Application(args.id).name(); return true;", arguments: ["id": bundleId], target: bundleId)
    }
    _ = automationState(bundleId, ask: true)
  }
}

private func automationState(_ bundleId: String, ask: Bool) -> GrantState {
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
