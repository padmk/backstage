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
  guard let components, let date = isoCalendar.date(from: components) else { return nil }
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
  try withEventStore(.reminder) { store, _ in
    let defaultId = store.defaultCalendarForNewReminders()?.calendarIdentifier
    return ["lists": store.calendars(for: .reminder).map { describe($0, isDefault: $0.calendarIdentifier == defaultId) }]
  }
}

private let list = Operation(
  name: "list", summary: "List reminders, soonest due first", effect: .reads,
  arguments: [
    Argument(name: "list", kind: .string, required: false, description: "List id or exact name; default all lists"),
    Argument(name: "include_completed", kind: .boolean, required: false, description: "Include completed reminders; default false"),
    Argument(name: "query", kind: .string, required: false, description: "Only reminders whose title or notes contain this, ignoring case"),
    limitArgument,
  ]
) { arguments in
  try withEventStore(.reminder) { store, _ in
    let calendars = try optionalString(arguments, "list").map { [try calendar($0, among: store.calendars(for: .reminder), kind: "list")] }
    let predicate = arguments["include_completed"] as? Bool == true
      ? store.predicateForReminders(in: calendars)
      : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
    let due = { (item: EKReminder) in item.dueDateComponents.flatMap { isoCalendar.date(from: $0) } ?? .distantFuture }
    let query = optionalString(arguments, "query")
    let matches = { (item: EKReminder) in
      query.map { ((item.title ?? "") + "\n" + (item.notes ?? "")).localizedCaseInsensitiveContains($0) } ?? true
    }
    let found = try fetch(predicate, in: store).filter(matches).sorted { due($0) < due($1) }
    return ["total": found.count, "has_more": found.count > limit(arguments), "reminders": found.prefix(limit(arguments)).map(describe)]
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
  try withEventStore(.reminder) { store, confirming in
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
      item.dueDateComponents = isoCalendar.dateComponents(fields, from: due.date)
      if !due.isDay { item.addAlarm(EKAlarm(absoluteDate: due.date)) }
    }
    item.notes = optionalString(arguments, "notes")
    item.priority = priorities[optionalString(arguments, "priority") ?? "none"] ?? 0
    try store.save(item, commit: true)
    let saved = try savedReminder(item.calendarItemIdentifier, in: confirming())
    var result = describe(saved)
    // Every field that was asked for, compared with what the store gives back.
    result["verified"] = saved.title == item.title && dueText(saved.dueDateComponents) == dueText(item.dueDateComponents)
      && (saved.notes ?? "") == (item.notes ?? "") && saved.priority == item.priority
      && saved.calendar.calendarIdentifier == item.calendar.calendarIdentifier
    return result
  }
}

// After a save succeeded, a reminder that cannot be read back may still have been saved, so the agent is told to
// look before trying again rather than that it does not exist.
private func savedReminder(_ id: String, in checking: EKEventStore) throws -> EKReminder {
  // Any failure to read the reminder back leaves the save unconfirmed, which is what the error says.
  guard let saved = try? reminder(id, in: checking) else {
    throw HelperError(code: "outcome_unknown", message: "Reminders saved the change but reminder \(id) cannot be read back. List the reminders before trying again.")
  }
  return saved
}

private let complete = Operation(
  name: "complete", summary: "Mark a reminder completed, or not completed again", effect: .changes,
  arguments: [
    Argument(name: "id", kind: .string, required: true, description: "Reminder id from list"),
    Argument(name: "completed", kind: .boolean, required: false, description: "Default true"),
  ]
) { arguments in
  try withEventStore(.reminder) { store, confirming in
    let item = try reminder(try string(arguments, "id"), in: store)
    try requireWritable(item.calendar, kind: "list")
    let wanted = arguments["completed"] as? Bool ?? true
    item.isCompleted = wanted
    try store.save(item, commit: true)
    let saved = try savedReminder(item.calendarItemIdentifier, in: confirming())
    var result = describe(saved)
    result["verified"] = saved.isCompleted == wanted
    return result
  }
}

private let read = Operation(
  name: "read", summary: "Read one reminder with its full notes", effect: .reads,
  arguments: [Argument(name: "id", kind: .string, required: true, description: "Reminder id from list")]
) { arguments in
  try withEventStore(.reminder) { store, _ in
    let item = try reminder(try string(arguments, "id"), in: store)
    var result = describe(item)
    if let notes = item.notes, !notes.isEmpty { result["notes"] = notes }
    return result
  }
}

private let update = Operation(
  name: "update", summary: "Change a reminder's title, due date, notes, priority or list; only the fields given change", effect: .changes,
  arguments: [
    Argument(name: "id", kind: .string, required: true, description: "Reminder id from list"),
    Argument(name: "title", kind: .string, required: false, description: "New title"),
    Argument(name: "due", kind: .string, required: false, description: "ISO 8601 date or local time, as for add; none removes the due date and its alert"),
    Argument(name: "notes", kind: .string, required: false, description: "New notes, replacing the old ones"),
    Argument(name: "priority", kind: .string, required: false, description: "New priority", allowed: ["none", "low", "medium", "high"]),
    Argument(name: "list", kind: .string, required: false, description: "List id or exact name to move it to"),
  ]
) { arguments in
  let fields = ["title", "due", "notes", "priority", "list"].filter { arguments[$0] is String }
  guard !fields.isEmpty else { throw HelperError(code: "invalid_arguments", message: "Give at least one field to change.") }
  let due = try (arguments["due"] as? String).flatMap { $0 == "none" ? nil : try moment($0, key: "due") }
  return try withEventStore(.reminder) { store, confirming in
    let item = try reminder(try string(arguments, "id"), in: store)
    try requireWritable(item.calendar, kind: "list")
    if let title = arguments["title"] as? String {
      guard !title.isEmpty else { throw HelperError(code: "invalid_arguments", message: "title cannot be empty.") }
      item.title = title
    }
    if arguments["due"] is String {
      // The alert at the due time moves with it; one set relative to the due time stays unless the due time goes.
      // Location alerts are left alone.
      for alarm in item.alarms ?? [] where alarm.structuredLocation == nil && (alarm.absoluteDate != nil || due == nil) {
        item.removeAlarm(alarm)
      }
      if let due {
        let fields: Set<Calendar.Component> = due.isDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute, .second, .timeZone]
        item.dueDateComponents = isoCalendar.dateComponents(fields, from: due.date)
        if !due.isDay { item.addAlarm(EKAlarm(absoluteDate: due.date)) }
      } else {
        item.dueDateComponents = nil
      }
    }
    if let notes = arguments["notes"] as? String { item.notes = notes }
    if let priority = arguments["priority"] as? String { item.priority = priorities[priority] ?? 0 }
    if let query = optionalString(arguments, "list") {
      item.calendar = try calendar(query, among: store.calendars(for: .reminder), kind: "list")
      try requireWritable(item.calendar, kind: "list")
    }
    try store.save(item, commit: true)
    let saved = try savedReminder(item.calendarItemIdentifier, in: confirming())
    var result = describe(saved)
    result["changed"] = fields
    result["verified"] = saved.title == item.title && dueText(saved.dueDateComponents) == dueText(item.dueDateComponents)
      && (saved.notes ?? "") == (item.notes ?? "") && saved.priority == item.priority
      && saved.calendar.calendarIdentifier == item.calendar.calendarIdentifier
    return result
  }
}

let remindersKnowledge = AppKnowledge(
  bundleId: "com.apple.reminders", name: "Reminders", summary: "List, find, read, add, change and complete reminders",
  access: "Read and change your reminders in every account, even while Reminders is closed",
  pitfalls: ["Operations work on the data directly, so the Reminders window may show a change a moment later."],
  operations: [listLists, list, read, add, update, complete])
