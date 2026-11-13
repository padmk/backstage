// Every string of the Backstage window and its menu bar item, in one place.

enum ControlTexts {
  static let appsTab = "Apps", activityTab = "Activity", setupTab = "Setup"

  static let appsHeading = "Apps agents may use"
  static let access = "Access"
  static let honesty = "This keeps agents from using other apps through Backstage by mistake. It does not stop an agent that can run shell commands: it can control your Mac without Backstage."
  static let everyApp = "Allow every app"
  static let everyAppOff = "Off: only the apps on the list below."
  static let everyAppOn = "On: agents may use any app except password managers, authenticators, wallets, login and permission windows, and Backstage."
  static let windowsWhileLocked = "Windows while locked"
  static let windowsWhileLockedOff = "Off: while the screen is locked, agents use ready operations and menus only."
  static let windowsWhileLockedOn = "On: while the screen is locked, agents see screenshots of the windows and click and type by position, unverified, through private macOS calls. The Mac stays locked."
  static let windowsWhileLockedConfirmTitle = "Let agents work in windows while the screen is locked?"
  static let windowsWhileLockedConfirmDetail = "macOS hides windows from other apps while the screen is locked. With this on, agents still see screenshots of the apps you allow and click and type in them, through private macOS calls, without any check that an action worked, and without you watching. The Mac stays locked and the displays stay asleep."
  static let windowsWhileLockedConfirm = "Turn On", cancel = "Cancel"
  static let add = "Add App…"
  static let requestsHeading = "Waiting for you"
  static let requestsNote = "Agents and the command line ask here. Nothing changes until you choose."
  static let addRequested = "Add", decline = "Decline", notNow = "Not Now"
  static func askedToUse(_ client: String) -> String { "\(client) wants to use this app" }
  static func askedToReach(_ client: String) -> String { "\(client) wants to use apps on this Mac over SSH" }
  static let computersHeading = "Other Macs agents may reach"
  static let computersNote = "Calls go there over SSH and that Mac's own app list decides them. A Mac that is not here is refused; agents ask for it above."
  static let computerDetail = "By the name ssh reaches it under"
  static func askedFor(_ client: String, _ purpose: String) -> String { "\(client) asked for this. \(purpose)" }
  static let waitingForMacOS = "Waiting for macOS…", openSettings = "Open Settings…"
  static let turnOnInSettings = "In System Settings, turn on Backstage. This updates by itself."
  static let noApps = "No apps yet", noAppsDetail = "Add the apps agents may use with Add App…\nAn app that is not here is refused, without asking."
  static let remove = "Remove"
  static func listKept(_ count: Int) -> String {
    "Your list of \(count) \(count == 1 ? "app" : "apps") is kept and applies again when you turn this off."
  }
  static let farReaching = "Gives agents a shell or control of your system"
  static let cannotAdd = "This app cannot be approved here.", saveFailed = "The change could not be saved."

  static let macOSPermissions = "macOS permissions"
  static let accessibility = "Accessibility", accessibilityPurpose = "Read windows, click and type"
  static let accessibilityNeeded = "Needed: without it, agents can do nothing through Backstage"
  static let appAccess = "App access"
  static let appAccessHint = "Ready operations of some apps need a macOS grant. macOS asks once, when you add the app; apps that are not on your list are never asked."
  static let noGrants = "Nothing to allow", noGrantsDetail = "Apps on your list that need a macOS grant appear here."
  static let allow = "Allow", allowed = "Allowed", unknownUntilOpen = "Unknown until the app is open"
  static let asking = "Waiting…"
  static let needsFullDiskAccess = "Needs Full Disk Access, which macOS does not ask for"
  static let addInSettings = "Add in Settings…"
  static let dragIntoList = "Drag into the Full Disk Access list in System Settings"
  static func dragTitle(_ name: String) -> String { "Let Backstage read \(name)" }
  static let dragSteps = "Drag this icon into the Full Disk Access list in System Settings, then turn it on. Or click + there and choose Backstage."
  static let done = "Done"
  static let grantsWaiting = "Some apps need a macOS grant for their ready operations.", showSetup = "Show"

  static let recentDecisions = "Recent activity"
  static let activityNote = "A local history of which agent first used which app in each session, and of changes to the list. It is not tamper-proof."
  static let noDecisions = "Nothing yet", noDecisionsDetail = "Apps agents use and changes to the list appear here."
  static let you = "You", commandLine = "Command line", anAgent = "An agent"

  static let background = "Background"
  static let openAtLogin = "Open at login", openAtLoginDetail = "Starts Backstage in the background when you log in."
  static let loginNeedsApproval = "Waiting for your approval in Login Items.", openLoginItems = "Open Login Items…"
  static let loginUnavailable = "Available when Backstage is in Applications."
  static func loginFailed(_ reason: String) -> String { "Could not change this: \(reason)." }
  static let showInMenuBar = "Show in menu bar", showInMenuBarDetail = "Status, agents and apps, one click away."
  static let keepsRunning = "While Open at login or Show in menu bar is on, Backstage keeps running instead of stopping when idle."
  static func version(_ name: String, _ number: String) -> String { "\(name) \(number)" }

  static let ready = "Ready"
  static func needs(_ what: String) -> String { "Needs \(what)" }
  static func connected(_ names: [String]) -> String { "Connected: \(names.joined(separator: ", "))" }
  static let noAgents = "No agents connected"
  static func andMore(_ count: Int) -> String { "and \(count) more" }
  static let openBackstage = "Open Backstage"
}
