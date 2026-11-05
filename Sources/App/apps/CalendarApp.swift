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
  if let notes = event.notes, !notes.isEmpty { result["notes"] = String(notes.prefix(500)) }
  return result
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
    return ["total": found.count, "events": found.prefix(limit(arguments)).map(describe)]
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
    result["verified"] = saved.title == event.title && saved.isAllDay == allDay
      && abs(saved.startDate.timeIntervalSince(event.startDate)) < 1 && abs(saved.endDate.timeIntervalSince(event.endDate)) < 1
    return result
  }
}

let calendarKnowledge = AppKnowledge(
  bundleId: "com.apple.iCal", name: "Calendar", summary: "List calendars and events, and create events",
  access: "Read and change your calendars in every account, even while Calendar is closed",
  pitfalls: [
    "Times without an offset are local time on this Mac.",
    "A recurring event appears once per occurrence in list_events, with the same id.",
  ],
  operations: [listCalendars, listEvents, createEvent])
