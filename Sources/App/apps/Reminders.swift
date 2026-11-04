// Reminders through EventKit.

import EventKit

private let priorities: [String: Int] = ["none": 0, "high": 1, "medium": 5, "low": 9]

private func priorityName(_ value: Int) -> String {
  switch value {
  case 1...4: "high"
  case 5: "medium"
  case 6...9: "low"
  default: "none"
  }
}

private func dueText(_ components: DateComponents?) -> String? {
  guard let components, let date = Calendar.current.date(from: components) else { return nil }
  return components.hour == nil ? dayText(date) : timeText(date)
}

private func describe(_ reminder: EKReminder) -> JSON {
  var result: JSON = [
    "id": reminder.calendarItemIdentifier, "title": reminder.title ?? "", "list": reminder.calendar?.title ?? "",
    "completed": reminder.isCompleted, "priority": priorityName(reminder.priority),
  ]
  if let due = dueText(reminder.dueDateComponents) { result["due"] = due }
  if let notes = reminder.notes, !notes.isEmpty { result["notes"] = String(notes.prefix(500)) }
  return result
}

private func fetch(_ predicate: NSPredicate, in store: EKEventStore) throws -> [EKReminder] {
  let done = DispatchSemaphore(value: 0)
  var found: [EKReminder] = []
  store.fetchReminders(matching: predicate) { reminders in
    found = reminders ?? []
    done.signal()
  }
  guard done.wait(timeout: .now() + 30) == .success else {
    throw HelperError(code: "timeout", message: "Reminders did not answer within 30 seconds.")
  }
  return found
}

private func reminder(_ id: String, in store: EKEventStore) throws -> EKReminder {
  guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
    throw HelperError(code: "not_found", message: "There is no reminder with id \(id).")
  }
  return item
}

private let listLists = Operation(name: "list_lists", summary: "List reminder lists with their ids", effect: .reads, arguments: []) { _ in
  try withEventStore(.reminder) { store in
    let defaultId = store.defaultCalendarForNewReminders()?.calendarIdentifier
    return ["lists": store.calendars(for: .reminder).map { describe($0, isDefault: $0.calendarIdentifier == defaultId) }]
  }
}

private let list = Operation(
  name: "list", summary: "List reminders, soonest due first", effect: .reads,
  arguments: [
    Argument(name: "list", kind: .string, required: false, description: "List id or exact name; default all lists"),
    Argument(name: "include_completed", kind: .boolean, required: false, description: "Include completed reminders; default false"),
    limitArgument,
  ]
) { arguments in
  try withEventStore(.reminder) { store in
    let calendars = try optionalString(arguments, "list").map { [try calendar($0, among: store.calendars(for: .reminder), kind: "list")] }
    let predicate = arguments["include_completed"] as? Bool == true
      ? store.predicateForReminders(in: calendars)
      : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
    let due = { (item: EKReminder) in item.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture }
    let found = try fetch(predicate, in: store).sorted { due($0) < due($1) }
    return ["total": found.count, "reminders": found.prefix(limit(arguments)).map(describe)]
  }
}

private let add = Operation(
  name: "add", summary: "Add a reminder", effect: .changes,
  arguments: [
    Argument(name: "title", kind: .string, required: true, description: "What to be reminded of"),
    Argument(name: "list", kind: .string, required: false, description: "List id or exact name; default the default list"),
    Argument(name: "due", kind: .string, required: false, description: "ISO 8601 date (2026-11-05) or local time (2026-11-05T09:00); a time also sets an alert"),
    Argument(name: "notes", kind: .string, required: false, description: "Notes"),
    Argument(name: "priority", kind: .string, required: false, description: "Default none", allowed: ["none", "low", "medium", "high"]),
  ]
) { arguments in
  try withEventStore(.reminder) { store in
    let item = EKReminder(eventStore: store)
    item.title = try string(arguments, "title")
    if let query = optionalString(arguments, "list") {
      item.calendar = try calendar(query, among: store.calendars(for: .reminder), kind: "list")
    } else if let fallback = store.defaultCalendarForNewReminders() {
      item.calendar = fallback
    } else {
      throw HelperError(code: "not_found", message: "There is no default list. Give one with list.")
    }
    try requireWritable(item.calendar, kind: "list")
    if let due = try optionalString(arguments, "due").map({ try moment($0, key: "due") }) {
      let fields: Set<Calendar.Component> = due.isDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute, .second, .timeZone]
      item.dueDateComponents = Calendar.current.dateComponents(fields, from: due.date)
      if !due.isDay { item.addAlarm(EKAlarm(absoluteDate: due.date)) }
    }
    item.notes = optionalString(arguments, "notes")
    item.priority = priorities[optionalString(arguments, "priority") ?? "none"] ?? 0
    try store.save(item, commit: true)
    let saved = try reminder(item.calendarItemIdentifier, in: confirmingStore())
    var result = describe(saved)
    result["verified"] = saved.title == item.title && dueText(saved.dueDateComponents) == dueText(item.dueDateComponents)
    return result
  }
}

private let complete = Operation(
  name: "complete", summary: "Mark a reminder completed, or not completed again", effect: .changes,
  arguments: [
    Argument(name: "id", kind: .string, required: true, description: "Reminder id from list"),
    Argument(name: "completed", kind: .boolean, required: false, description: "Default true"),
  ]
) { arguments in
  try withEventStore(.reminder) { store in
    let item = try reminder(try string(arguments, "id"), in: store)
    try requireWritable(item.calendar, kind: "list")
    let wanted = arguments["completed"] as? Bool ?? true
    item.isCompleted = wanted
    try store.save(item, commit: true)
    let saved = try reminder(item.calendarItemIdentifier, in: confirmingStore())
    var result = describe(saved)
    result["verified"] = saved.isCompleted == wanted
    return result
  }
}

let remindersKnowledge = AppKnowledge(
  bundleId: "com.apple.reminders", name: "Reminders", summary: "List, add and complete reminders",
  access: "Can also read and change your reminders in every account, even while Reminders is closed.",
  pitfalls: ["Operations work on the data directly, so the Reminders window may show a change a moment later."],
  operations: [listLists, list, add, complete])
