// Every string of the Backstage window and its menu bar item, in one place.

enum ControlTexts {
  static let appsTab = "Apps", permissionsTab = "Permissions", activityTab = "Activity", generalTab = "General"

  static let appsHeading = "Approved apps"
  static let add = "Add App…"
  static let noApps = "No apps yet", noAppsDetail = "An agent asks the first time it needs an app.\nOr add one with Add App…"
  static let always = "Always", oneHour = "1 hour", oneDay = "1 day", oneWeek = "1 week", session = "This session", remove = "Remove"
  static func until(_ text: String) -> String { "Until \(text)" }
  static let farReaching = "Can run commands or change your system"
  static let cannotAdd = "This app cannot be approved here.", saveFailed = "The change could not be saved."

  static let macOSPermissions = "macOS permissions"
  static let accessibility = "Accessibility", accessibilityPurpose = "Read windows, click and type"
  static let screenRecording = "Screen Recording", screenRecordingPurpose = "Screenshots of app windows"
  static let granted = "Granted", missing = "Missing", openSettings = "Open Settings…", restart = "Restart"
  static let restartHint = "A new Screen Recording grant applies after a restart, which ends session approvals."
  static let appAccess = "App access", allowAll = "Allow All…"
  static let appAccessHint = "Allow these once so tasks do not stop to ask. Agents still need approval per app."
  static let allow = "Allow", allowed = "Allowed", off = "Off", unknownUntilOpen = "Unknown until the app is open"
  static let asking = "Waiting…"
  static let grantThenRestart = "Grant it, then restart Backstage"

  static let recentDecisions = "Recent decisions"
  static let noDecisions = "No decisions yet", noDecisionsDetail = "Answers to approval requests appear here."
  static let you = "You", anAgent = "An agent"

  static let background = "Background"
  static let openAtLogin = "Open at login", openAtLoginDetail = "Starts Backstage in the background when you log in."
  static let loginNeedsApproval = "Waiting for your approval in Login Items.", openLoginItems = "Open Login Items…"
  static let loginUnavailable = "Available when Backstage is in Applications."
  static func loginFailed(_ reason: String) -> String { "Could not change this: \(reason)." }
  static let showInMenuBar = "Show in menu bar", showInMenuBarDetail = "Status, agents and apps, one click away."
  static let keepsRunning = "While either is on, Backstage keeps running instead of stopping when idle."
  static func version(_ name: String, _ number: String) -> String { "\(name) \(number)" }

  static let ready = "Ready"
  static func needs(_ what: String) -> String { "Needs \(what)" }
  static func connected(_ names: [String]) -> String { "Connected: \(names.joined(separator: ", "))" }
  static let noAgents = "No agents connected"
  static func andMore(_ count: Int) -> String { "and \(count) more" }
  static let openBackstage = "Open Backstage"
}
