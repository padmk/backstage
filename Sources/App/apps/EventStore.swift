// The event store behind Reminders and Calendar, and the time format their operations share. EventKit
// reaches the data directly, so these operations touch no app.

import EventKit

private let accessRequestSeconds = 170
private let lock = NSLock()
private var store = EKEventStore()
private var checkingStore = EKEventStore()

// One operation at a time, because the store is shared and saving is not safe to interleave.
func withEventStore<T>(_ type: EKEntityType, _ work: (EKEventStore) throws -> T) throws -> T {
  try lock.withLock {
    try requireAccess(to: type)
    return try work(store)
  }
}

// A store of its own, emptied of cached objects, so a read-back sees what was saved rather than the object
// still in memory.
func confirmingStore() -> EKEventStore {
  checkingStore.reset()
  return checkingStore
}

private func requireAccess(to type: EKEntityType) throws {
  let pane = type == .reminder ? "Reminders" : "Calendars"
  switch EKEventStore.authorizationStatus(for: type) {
  case .fullAccess:
    return
  case .notDetermined:
    let answered = DispatchSemaphore(value: 0)
    var granted = false
    let completion: EKEventStoreRequestAccessCompletionHandler = { result, _ in
      granted = result
      answered.signal()
    }
    if type == .reminder { store.requestFullAccessToReminders(completion: completion) } else { store.requestFullAccessToEvents(completion: completion) }
    guard answered.wait(timeout: .now() + .seconds(accessRequestSeconds)) == .success else {
      throw HelperError(code: "access_denied", message: "macOS asked whether Backstage may use \(pane) and got no answer. Try again and answer the prompt.")
    }
    guard granted else { throw accessDenied(pane) }
    // A store made before the grant does not see the accounts.
    store = EKEventStore()
    checkingStore = EKEventStore()
  default:
    throw accessDenied(pane)
  }
}

private func accessDenied(_ pane: String) -> HelperError {
  HelperError(code: "access_denied", message: "macOS does not let Backstage use \(pane). Allow full access in System Settings > Privacy & Security > \(pane) > Backstage, then try again.")
}

// Finds a list or calendar by identifier or by an exact title that only one has.
func calendar(_ query: String, among calendars: [EKCalendar], kind: String) throws -> EKCalendar {
  if let match = calendars.first(where: { $0.calendarIdentifier == query }) { return match }
  let named = calendars.filter { $0.title == query }
  guard !named.isEmpty else { throw HelperError(code: "not_found", message: "There is no \(kind) \(query). Use the list operation for ids.") }
  guard named.count == 1 else { throw HelperError(code: "ambiguous", message: "Several \(kind)s are named \(query). Give its id.") }
  return named[0]
}

func requireWritable(_ calendar: EKCalendar, kind: String) throws {
  guard calendar.allowsContentModifications else {
    throw HelperError(code: "not_allowed", message: "The \(kind) \(calendar.title) is read-only.")
  }
}

func describe(_ calendar: EKCalendar, isDefault: Bool) -> JSON {
  ["id": calendar.calendarIdentifier, "title": calendar.title, "account": calendar.source?.title ?? "", "writable": calendar.allowsContentModifications, "default": isDefault]
}

// MARK: Times

struct Moment {
  let date: Date
  // A date with no time of day, such as 2026-11-05.
  let isDay: Bool
}

private func formatter(_ format: String) -> DateFormatter {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = .current
  formatter.dateFormat = format
  return formatter
}

// ISO 8601: a date, or a date and time with or without an offset; without one it is local time.
func moment(_ text: String, key: String) throws -> Moment {
  if let day = formatter("yyyy-MM-dd").date(from: text), text.count == 10 { return Moment(date: day, isDay: true) }
  for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = options
    if let date = iso.date(from: text) { return Moment(date: date, isDay: false) }
  }
  for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
    if let date = formatter(format).date(from: text) { return Moment(date: date, isDay: false) }
  }
  throw HelperError(code: "invalid_arguments", message: "\(key) must be an ISO 8601 date or time, such as 2026-11-05 or 2026-11-05T14:30.")
}

func timeText(_ date: Date) -> String {
  let iso = ISO8601DateFormatter()
  iso.timeZone = .current
  iso.formatOptions = [.withInternetDateTime]
  return iso.string(from: date)
}

func dayText(_ date: Date) -> String { formatter("yyyy-MM-dd").string(from: date) }

// MARK: Access, for the App Access list

func eventAccessState(_ type: EKEntityType) -> GrantState {
  switch EKEventStore.authorizationStatus(for: type) {
  case .fullAccess: .granted
  case .notDetermined: .notAsked
  default: .denied
  }
}

// Shows macOS's prompt when it has not asked yet.
func requestEventAccess(_ type: EKEntityType) {
  _ = try? lock.withLock { try requireAccess(to: type) }
}
