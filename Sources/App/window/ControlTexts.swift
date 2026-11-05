// Every string of the Backstage window and its menu bar item, in one place.

enum ControlTexts {
  static let appsTab = "Apps", activityTab = "Activity", setupTab = "Setup"

  static let appsHeading = "Apps agents may use"
  static let access = "Access"
  static let honesty = "This keeps agents from using other apps through Backstage by mistake. It does not stop an agent that can run shell commands: it can control your Mac without Backstage."
  static let everyApp = "Allow every app"
  static let everyAppOff = "Off: only the apps on the list below."
  static let everyAppOn = "On: agents may use any app except Passwords, Keychain Access and Backstage."
  static let windowsWhileLocked = "Windows while locked"
  static let windowsWhileLockedOff = "Off: while the screen is locked, agents use ready operations and menus only."
  static let windowsWhileLockedOn = "On: while the screen is locked, agents see screenshots of the windows and click and type by position, unverified, through private macOS calls. The Mac stays locked."
  static let add = "Add App…"
  static let noApps = "No apps yet", noAppsDetail = "Add the apps agents may use with Add App…\nAn app that is not here is refused, without asking."
  static let remove = "Remove"
  static func listKept(_ count: Int) -> String {
    "Your list of \(count) \(count == 1 ? "app" : "apps") is kept and applies again when you turn this off."
  }
  static let farReaching = "Gives agents a shell or control of your system"
  static let cannotAdd = "This app cannot be approved here.", saveFailed = "The change could not be saved."

  static let macOSPermissions = "macOS permissions"
  static let accessibility = "Accessibility", accessibilityPurpose = "Read windows, click and type"
  static let screenRecording = "Screen Recording", screenRecordingPurpose = "Screenshots of app windows"
  static let screenRecordingOptional = "Optional: screenshots, for web pages and apps that show no elements"
  static let granted = "Granted", missing = "Missing", openSettings = "Open Settings…", restart = "Restart"
  static let restartHint = "A new Screen Recording grant applies after Backstage restarts."
  static let appAccess = "App access"
  static let appAccessHint = "Ready operations of some apps need a macOS grant. macOS asks once, when you add the app; apps that are not on your list are never asked."
  static let noGrants = "Nothing to allow", noGrantsDetail = "Apps on your list that need a macOS grant appear here."
  static let allow = "Allow", allowed = "Allowed", off = "Off", unknownUntilOpen = "Unknown until the app is open"
  static let asking = "Waiting…"

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
