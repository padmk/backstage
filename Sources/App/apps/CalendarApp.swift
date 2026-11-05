// Calendar through EventKit.

import EventKit

private let maxRangeDays = 366.0

private func describe(_ event: EKEvent) -> JSON {
  var result: JSON = [
    "id": event.eventIdentifier ?? "", "title": event.title ?? "", "calendar": event.calendar?.title ?? "",
    "all_day": event.isAllDay, "recurring": event.hasRecurrenceRules,
  ]
  if event.isAllDay {
    result["start"] = dayText(event.startDate)
    // EventKit ends an all-day event at the end of its last day; the contract names that day.
    result["end"] = dayText(event.endDate.addingTimeInterval(-1))
  } else {
    result["start"] = timeText(event.startDate)
    result["end"] = timeText(event.endDate)
  }
  if let location = event.location, !location.isEmpty { result["location"] = location }
  if let notes = event.notes, !notes.isEmpty {
    result["notes"] = String(notes.prefix(listedNotesLength))
    if notes.count > listedNotesLength { result["notes_cut"] = true }
  }
  return result
}

// Lists show the start of long notes; get_event shows them in full.
private let listedNotesLength = 500

private let getEvent = Operation(
  name: "get_event", summary: "Read one event in full: all its notes, its link, attendees and organizer", effect: .reads,
  arguments: [Argument(name: "id", kind: .string, required: true, description: "Event id from list_events")]
) { arguments in
  let id = try string(arguments, "id")
  return try withEventStore(.event) { store -> JSON in
    guard let event = store.event(withIdentifier: id) else { throw HelperError(code: "not_found", message: "There is no event with id \(id).") }
    var result = describe(event)
    result["notes"] = event.notes ?? ""
    result["notes_cut"] = nil
    if let url = event.url { result["url"] = url.absoluteString }
    if let organizer = event.organizer { result["organizer"] = organizer.name ?? organizer.url.absoluteString }
    if let attendees = event.attendees, !attendees.isEmpty {
      result["attendees"] = attendees.map { person -> JSON in
        var entry: JSON = ["name": person.name ?? "", "status": statusName(person.participantStatus)]
        if person.url.scheme == "mailto" { entry["email"] = person.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") }
        return entry
      }
    }
    if event.hasRecurrenceRules { result["note"] = "A recurring event: this is its first occurrence; list_events shows each one." }
    return result
  }
}

private func statusName(_ status: EKParticipantStatus) -> String {
  switch status {
  case .accepted: return "accepted"
  case .declined: return "declined"
  case .tentative: return "tentative"
  case .pending: return "pending"
  case .delegated: return "delegated"
  case .completed: return "completed"
  case .inProcess: return "in_process"
  default: return "unknown"
  }
}

private let listCalendars = Operation(name: "list_calendars", summary: "List calendars with their ids", effect: .reads, arguments: []) { _ in
  try withEventStore(.event) { store in
    let defaultId = store.defaultCalendarForNewEvents?.calendarIdentifier
    return ["calendars": store.calendars(for: .event).map { describe($0, isDefault: $0.calendarIdentifier == defaultId) }]
  }
}

private let listEvents = Operation(
  name: "list_events", summary: "List events that overlap a time range, earliest first", effect: .reads,
  arguments: [
    Argument(name: "start", kind: .string, required: true, description: "ISO 8601 date or time; a date means its start"),
    Argument(name: "end", kind: .string, required: true, description: "ISO 8601 date or time; a date means the end of that day. At most 366 days after start"),
    Argument(name: "calendar", kind: .string, required: false, description: "Calendar id or exact name; default all"),
    limitArgument,
  ]
) { arguments in
  let start = try moment(string(arguments, "start"), key: "start").date
  let endMoment = try moment(string(arguments, "end"), key: "end")
  let end = endMoment.isDay ? isoCalendar.date(byAdding: .day, value: 1, to: endMoment.date)! : endMoment.date
  guard end > start else { throw HelperError(code: "invalid_arguments", message: "end must be after start.") }
  guard end.timeIntervalSince(start) <= maxRangeDays * 86400 else {
    throw HelperError(code: "invalid_arguments", message: "The range may span at most 366 days.")
  }
  return try withEventStore(.event) { store -> JSON in
    let calendars = try optionalString(arguments, "calendar").map { [try calendar($0, among: store.calendars(for: .event), kind: "calendar")] }
    let found = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars))
      .sorted { $0.startDate < $1.startDate }
    return ["total": found.count, "has_more": found.count > limit(arguments), "events": found.prefix(limit(arguments)).map(describe)]
  }
}

private let createEvent = Operation(
  name: "create_event", summary: "Create an event", effect: .changes,
  arguments: [
    Argument(name: "title", kind: .string, required: true, description: "Title"),
    Argument(name: "start", kind: .string, required: true, description: "ISO 8601 time, local without an offset; a date for an all-day event"),
    Argument(name: "end", kind: .string, required: true, description: "ISO 8601 time; for an all-day event the last day, inclusive"),
    Argument(name: "all_day", kind: .boolean, required: false, description: "Default false"),
    Argument(name: "calendar", kind: .string, required: false, description: "Calendar id or exact name; default the default calendar"),
    Argument(name: "location", kind: .string, required: false, description: "Location"),
    Argument(name: "notes", kind: .string, required: false, description: "Notes"),
  ]
) { arguments in
  let allDay = arguments["all_day"] as? Bool ?? false
  let start = try moment(string(arguments, "start"), key: "start")
  let end = try moment(string(arguments, "end"), key: "end")
  guard start.isDay == allDay, end.isDay == allDay else {
    throw HelperError(code: "invalid_arguments", message: allDay ? "An all-day event takes dates, such as 2026-11-05." : "start and end need a time of day; for a whole day set all_day.")
  }
  guard allDay ? end.date >= start.date : end.date > start.date else {
    throw HelperError(code: "invalid_arguments", message: "end must be after start.")
  }
  return try withEventStore(.event) { store -> JSON in
    let event = EKEvent(eventStore: store)
    event.title = try string(arguments, "title")
    event.isAllDay = allDay
    event.startDate = start.date
    event.endDate = allDay ? isoCalendar.date(byAdding: .day, value: 1, to: end.date)!.addingTimeInterval(-1) : end.date
    event.location = optionalString(arguments, "location")
    event.notes = optionalString(arguments, "notes")
    if let query = optionalString(arguments, "calendar") {
      event.calendar = try calendar(query, among: store.calendars(for: .event), kind: "calendar")
    } else if let fallback = store.defaultCalendarForNewEvents {
      event.calendar = fallback
    } else {
      throw HelperError(code: "not_found", message: "There is no default calendar. Give one with calendar.")
    }
    try requireWritable(event.calendar, kind: "calendar")
    try store.save(event, span: .thisEvent, commit: true)
    guard let id = event.eventIdentifier, let saved = confirmingStore().event(withIdentifier: id) else {
      throw HelperError(code: "outcome_unknown", message: "Calendar saved the event but it cannot be read back. List the events before trying again.")
    }
    var result = describe(saved)
    // Every field that was asked for, compared with what the store gives back.
    result["verified"] = saved.title == event.title && saved.isAllDay == allDay
      && abs(saved.startDate.timeIntervalSince(event.startDate)) < 1 && abs(saved.endDate.timeIntervalSince(event.endDate)) < 1
      && (saved.location ?? "") == (event.location ?? "") && (saved.notes ?? "") == (event.notes ?? "")
      && saved.calendar.calendarIdentifier == event.calendar.calendarIdentifier
    return result
  }
}

private let updateEvent = Operation(
  name: "update_event", summary: "Change one event's title, times, location, notes or calendar; only the fields given change. A recurring event is refused", effect: .changes,
  arguments: [
    Argument(name: "id", kind: .string, required: true, description: "Event id from list_events"),
    Argument(name: "title", kind: .string, required: false, description: "New title"),
    Argument(name: "start", kind: .string, required: false, description: "New start, in the event's kind (a time, or a date for an all-day event); without end, the event keeps its length"),
    Argument(name: "end", kind: .string, required: false, description: "New end; for an all-day event the last day, inclusive"),
    Argument(name: "location", kind: .string, required: false, description: "New location; empty removes it"),
    Argument(name: "notes", kind: .string, required: false, description: "New notes, replacing the old ones"),
    Argument(name: "calendar", kind: .string, required: false, description: "Calendar id or exact name to move it to"),
  ]
) { arguments in
  let fields = ["title", "start", "end", "location", "notes", "calendar"].filter { arguments[$0] is String }
  guard !fields.isEmpty else { throw HelperError(code: "invalid_arguments", message: "Give at least one field to change.") }
  let start = try optionalString(arguments, "start").map { try moment($0, key: "start") }
  let end = try optionalString(arguments, "end").map { try moment($0, key: "end") }
  return try withEventStore(.event) { store -> JSON in
    let id = try string(arguments, "id")
    guard let event = store.event(withIdentifier: id) else { throw HelperError(code: "not_found", message: "There is no event with id \(id).") }
    // Every occurrence of a recurring event shares the id, so a change could reach the whole series.
    guard !event.hasRecurrenceRules, !event.isDetached else { throw HelperError(code: "not_allowed", message: "\(event.title ?? id) repeats; changing a recurring event is not supported. Change it in Calendar.") }
    try requireWritable(event.calendar, kind: "calendar")
    let allDay = event.isAllDay
    for given in [start, end].compactMap({ $0 }) where given.isDay != allDay {
      throw HelperError(code: "invalid_arguments", message: allDay ? "This is an all-day event, so it takes dates, such as 2026-11-05." : "This event has times, so start and end need a time of day.")
    }
    // An all-day event keeps its number of days, which a clock change would break if counted in seconds.
    let length = event.endDate.timeIntervalSince(event.startDate)
    // Counted to the last day the event covers: some sources end an all-day event at the next midnight, others a
    // second before it.
    let days = isoCalendar.dateComponents([.day], from: isoCalendar.startOfDay(for: event.startDate),
                                          to: isoCalendar.startOfDay(for: event.endDate.addingTimeInterval(-1))).day ?? 0
    let lastDay = { (day: Date) in isoCalendar.date(byAdding: .day, value: 1, to: day)!.addingTimeInterval(-1) }
    if let start { event.startDate = start.date }
    if let end {
      event.endDate = allDay ? lastDay(end.date) : end.date
    } else if let start {
      event.endDate = allDay ? lastDay(isoCalendar.date(byAdding: .day, value: days, to: start.date)!) : start.date.addingTimeInterval(length)
    }
    guard event.endDate > event.startDate else { throw HelperError(code: "invalid_arguments", message: "end must be after start.") }
    if let title = arguments["title"] as? String {
      guard !title.isEmpty else { throw HelperError(code: "invalid_arguments", message: "title cannot be empty.") }
      event.title = title
    }
    if let location = arguments["location"] as? String { event.location = location.isEmpty ? nil : location }
    if let notes = arguments["notes"] as? String { event.notes = notes }
    if let query = optionalString(arguments, "calendar") {
      event.calendar = try calendar(query, among: store.calendars(for: .event), kind: "calendar")
      try requireWritable(event.calendar, kind: "calendar")
    }
    try store.save(event, span: .thisEvent, commit: true)
    guard let savedId = event.eventIdentifier, let saved = confirmingStore().event(withIdentifier: savedId) else {
      throw HelperError(code: "outcome_unknown", message: "Calendar saved the change but the event cannot be read back. List the events before trying again.")
    }
    var result = describe(saved)
    result["changed"] = fields
    result["verified"] = saved.title == event.title
      && abs(saved.startDate.timeIntervalSince(event.startDate)) < 1 && abs(saved.endDate.timeIntervalSince(event.endDate)) < 1
      && (saved.location ?? "") == (event.location ?? "") && (saved.notes ?? "") == (event.notes ?? "")
      && saved.calendar.calendarIdentifier == event.calendar.calendarIdentifier
    return result
  }
}

let calendarKnowledge = AppKnowledge(
  bundleId: "com.apple.iCal", name: "Calendar", summary: "List calendars and events, and create and change events",
  access: "Read and change your calendars in every account, even while Calendar is closed",
  pitfalls: [
    "Times without an offset are local time on this Mac.",
    "A recurring event appears once per occurrence in list_events, with the same id.",
    "list_events shows the start of long notes (notes_cut); get_event shows them in full.",
  ],
  operations: [listCalendars, listEvents, getEvent, createEvent, updateEvent])
