// Messages conversations from its own database (~/Library/Messages/chat.db), read-only, so reading a chat needs no
// window, no scrolling and no running app. macOS guards the folder; Full Disk Access opens it, as for WhatsApp.
// The format is Apple's own and undocumented: a version without the columns read here fails with
// unsupported_format, and the window still works then.

import Foundation

let messagesDatabasePath = NSHomeDirectory() + "/Library/Messages/chat.db"
private let attachmentsFolder = NSHomeDirectory() + "/Library/Messages/Attachments"

private let defaultMessages = 50
private let maxMessages = 500
// Dates above this are nanoseconds since 2001, as current macOS stores them; older databases kept seconds.
private let nanosecondDates = 1_000_000_000_000.0

private let requiredColumns: [String: Set<String>] = [
  "chat": ["ROWID", "guid", "chat_identifier", "display_name"],
  "chat_message_join": ["chat_id", "message_id"],
  "message": ["ROWID", "text", "attributedBody", "date", "is_from_me", "handle_id", "associated_message_type", "item_type", "cache_has_attachments"],
  "handle": ["ROWID", "id"],
  "chat_handle_join": ["chat_id", "handle_id"],
]
private let attachmentColumns: [String: Set<String>] = [
  "message_attachment_join": ["message_id", "attachment_id"],
  "attachment": ["ROWID", "filename", "mime_type", "transfer_name"],
]

func messagesHistoryGranted() -> Bool {
  appGrants.first { $0.id == "messages-history" }.map { grantState($0) == .granted } ?? false
}

func openMessagesDatabase(at path: String = messagesDatabasePath) throws -> ReadOnlyDatabase {
  let database = try ReadOnlyDatabase(path: path, appName: "Messages")
  _ = try database.requireColumns(requiredColumns)
  return database
}

private func seconds(_ value: Any??) -> Double? {
  guard let value = value ?? nil else { return nil }
  let raw: Double? = (value as? Int64).map(Double.init) ?? (value as? Double)
  return raw.map { $0 > nanosecondDates ? $0 / 1_000_000_000 : $0 }
}

private func int(_ value: Any??) -> Int64? { (value ?? nil) as? Int64 }
private func text(_ value: Any??) -> String? {
  guard let text = (value ?? nil) as? String, !text.isEmpty else { return nil }
  return text
}

// Messages keeps no names for people; Messages shows the names in Contacts, which label chats here when the user
// has allowed Contacts. Business senders, such as "Orange", are named by their handle and are not looked up.
private func person(_ handle: String?, _ contacts: ContactLookup?) -> HandleContact? {
  guard let contacts, let handle, let parsed = ContactHandle(handle) else { return nil }
  return contacts(parsed)
}

// Names compared as people type them: without case, accents or strokes, so "lodz" finds "Łódź".
func searchFolded(_ text: String) -> String {
  String(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).map { letter in
    switch letter {
    case "ł": "l"
    case "ø": "o"
    case "đ": "d"
    case "ı": "i"
    default: letter
    }
  })
}

// Each chat's participants' handles, in the order Messages added them.
private func participants(_ database: ReadOnlyDatabase) throws -> [Int64: [String]] {
  try database.rows("""
    SELECT x.chat_id AS chat, h.id AS handle FROM chat_handle_join x JOIN handle h ON h.ROWID = x.handle_id ORDER BY h.ROWID
    """).reduce(into: [Int64: [String]]()) { map, row in
      if let chat = int(row["chat"]), let handle = text(row["handle"]) { map[chat, default: []].append(handle) }
    }
}

// The handle of the one other person in a chat, or nil for a group.
private func otherPerson(_ participants: [String], identifier: String?) -> String? {
  participants.count > 1 ? nil : participants.first ?? identifier
}

// A chat by the id list_chats gives (its guid), else by the one handle or group id it is known by, else by its name,
// else by the contact name of the one person in it; more than one match is refused. A person reached over several
// services, such as iMessage and SMS, has a chat for each under the same handle: those read as one conversation,
// addressed by the handle, and so do the one-to-one chats of the one contact a name gives.
private func chat(_ database: ReadOnlyDatabase, _ wanted: String, contacts: ContactLookup?) throws -> (keys: [Int64], id: String, name: String) {
  let rows = try database.rows("SELECT ROWID, guid, chat_identifier, display_name FROM chat")
  let tiers: [([String: Any?]) -> Bool] = [
    { text($0["guid"]) == wanted },
    { text($0["chat_identifier"]) == wanted },
    { text($0["display_name"])?.caseInsensitiveCompare(wanted) == .orderedSame },
  ]
  for (tier, matches) in tiers.map({ rows.filter($0) }).enumerated() where !matches.isEmpty {
    let keys = matches.compactMap { int($0["ROWID"]) }
    let fallback = { (handle: String) in person(handle, contacts)?.name ?? handle }
    if matches.count == 1, let row = matches.first, let key = keys.first {
      return ([key], text(row["guid"]) ?? "", text(row["display_name"]) ?? text(row["chat_identifier"]).map(fallback) ?? "")
    }
    if tier == 1, keys.count == matches.count, try oneToOne(database, keys) {
      return (keys, wanted, matches.lazy.compactMap { text($0["display_name"]) }.first ?? fallback(wanted))
    }
    throw HelperError(code: "ambiguous", message: "\(matches.count) chats match \(wanted). Use the id from list_chats.")
  }
  if let contacts {
    let members = try participants(database)
    let folded = searchFolded(wanted.trimmingCharacters(in: .whitespaces))
    let matches = rows.compactMap { row -> (key: Int64, handle: String, contact: HandleContact)? in
      guard let key = int(row["ROWID"]), text(row["display_name"]) == nil,
        let handle = otherPerson(members[key] ?? [], identifier: text(row["chat_identifier"])),
        let contact = person(handle, contacts), searchFolded(contact.name) == folded
      else { return nil }
      return (key, handle, contact)
    }
    let people = Set(matches.map(\.contact.id))
    if people.count == 1, let contact = matches.first?.contact {
      let handles = Set(matches.map(\.handle))
      return (matches.map(\.key), handles.count == 1 ? handles.first ?? contact.name : contact.name, contact.name)
    }
    if people.count > 1 {
      throw HelperError(code: "ambiguous", message: "\(people.count) people in Contacts are named \(wanted). Use a phone number, an email address or the id from list_chats.")
    }
  }
  throw HelperError(code: "not_found", message: "No chat has the id, handle or name \(wanted). Use list_chats.")
}

// Whether none of the chats has more than one other participant, so chats sharing a handle are one person's.
private func oneToOne(_ database: ReadOnlyDatabase, _ keys: [Int64]) throws -> Bool {
  let rows = try database.rows("""
    SELECT COUNT(*) AS participants FROM chat_handle_join WHERE chat_id IN (\(placeholders(keys.count))) GROUP BY chat_id
    """, keys)
  return rows.allSatisfy { (int($0["participants"]) ?? 0) <= 1 }
}

// ?1 to ?count, for a list of values bound first.
private func placeholders(_ count: Int) -> String {
  (1...count).map { "?\($0)" }.joined(separator: ", ")
}

// The chats as list_chats gives them, latest first, from the database: ids, names, participants' handles with the
// names Contacts gives them, and when the last message came.
func messagesChatList(_ database: ReadOnlyDatabase, query: String?, limit: Int, contacts: ContactLookup?) throws -> JSON {
  let chats = try database.rows("""
    SELECT c.ROWID AS key, c.guid AS id, c.display_name AS name, c.chat_identifier AS identifier,
      (SELECT MAX(m.date) FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id WHERE j.chat_id = c.ROWID) AS last
    FROM chat c ORDER BY last IS NULL, last DESC
    """)
  let members = try participants(database)
  let wanted = query.map(searchFolded).flatMap { $0.isEmpty ? nil : $0 }
  let described = chats.compactMap { row -> JSON? in
    let handles = members[int(row["key"]) ?? -1] ?? []
    let identifier = text(row["identifier"])
    var chat: JSON = ["id": text(row["id"]) ?? "", "name": text(row["name"]) ?? "", "participants": handles]
    if let last = seconds(row["last"]) { chat["last_message"] = timeText(Date(timeIntervalSinceReferenceDate: last)) }
    if let identifier { chat["handle"] = identifier }
    // A one-to-one chat without participants rows is known by its identifier alone.
    let other = otherPerson(handles, identifier: identifier)
    let named = Dictionary((handles.isEmpty ? other.map { [$0] } ?? [] : handles).compactMap { handle in
      person(handle, contacts).map { (handle, $0.name) }
    }, uniquingKeysWith: { first, _ in first })
    if !named.isEmpty { chat["contact_names"] = named }
    if text(row["name"]) == nil, let other, let name = named[other] { chat["name"] = name }
    if let wanted {
      let texts = [chat["name"] as? String ?? "", identifier ?? ""] + handles + Array(named.values)
      guard texts.contains(where: { searchFolded($0).contains(wanted) }) else { return nil }
    }
    return chat
  }
  let shown = Array(described.prefix(limit))
  var result: JSON = ["total": described.count, "has_more": described.count > shown.count, "chats": shown, "source": "database"]
  if wanted != nil, described.isEmpty, contacts == nil {
    result["note"] = "Messages keeps no names for people; it shows the names in Contacts. Backstage matches names once the user allows Contacts on the Setup tab (after adding Contacts on the Apps tab); until then, search by phone number or email address."
  }
  return result
}

let messagesReadChat = Operation(
  name: "read_chat", summary: "Read a conversation's messages, oldest first, from Messages' data on this Mac", effect: .reads,
  arguments: [
    Argument(name: "chat", kind: .string, required: true, description: "Chat id from list_chats, a phone number or email address of a one-to-one chat, a group's name, or a person's name in Contacts"),
    Argument(name: "since", kind: .string, required: false, description: "Only messages from this time on: an ISO 8601 date or time"),
    Argument(name: "until", kind: .string, required: false, description: "Only messages before this time"),
    Argument(name: "before", kind: .integer, required: false, description: "Only messages older than this message id; pass the first message's id to read earlier ones", minimum: 1),
    Argument(name: "limit", kind: .integer, required: false, description: "Most messages to return, the latest in the range; default \(defaultMessages)", minimum: 1, maximum: maxMessages),
  ]
) { arguments in
  try readMessagesChat(openMessagesDatabase(), arguments, contacts: contactLookup())
}

func readMessagesChat(_ database: ReadOnlyDatabase, _ arguments: JSON, contacts: ContactLookup? = nil) throws -> JSON {
  let found = try chat(database, try string(arguments, "chat"), contacts: contacts)
  let inChat = "m.ROWID IN (SELECT message_id FROM chat_message_join WHERE chat_id IN (\(placeholders(found.keys.count))))"
  // Reactions and other messages that point at another one are left out; they are not messages of their own.
  var conditions = [inChat, "IFNULL(m.associated_message_type, 0) = 0"]
  var bindings: [Any?] = found.keys
  // Times are compared in seconds, whatever unit the database stores.
  let when = "(CASE WHEN m.date > \(Int64(nanosecondDates)) THEN m.date / 1000000000.0 ELSE m.date END)"
  for (key, comparison) in [("since", ">="), ("until", "<")] {
    if let value = optionalString(arguments, key) {
      bindings.append(try moment(value, key: key).date.timeIntervalSinceReferenceDate)
      conditions.append("\(when) \(comparison) ?\(bindings.count)")
    }
  }
  // By date, then id, as the messages are ordered, so messages sharing a time are neither skipped nor repeated.
  if let before = arguments["before"] as? Int {
    let rows = try database.rows("SELECT \(when) AS at FROM message m WHERE \(inChat) AND m.ROWID = ?\(found.keys.count + 1)", found.keys + [before])
    // Seconds come back as whole numbers from a database that stored them so.
    guard let at = rows.first.flatMap({ seconds($0["at"]) }) else {
      throw HelperError(code: "not_found", message: "Message \(before) is not in this chat.")
    }
    bindings.append(at)
    let date = bindings.count
    bindings.append(before)
    conditions.append("(\(when) < ?\(date) OR (\(when) = ?\(date) AND m.ROWID < ?\(bindings.count)))")
  }
  let count = arguments["limit"] as? Int ?? defaultMessages
  // One more than asked, to tell whether earlier messages remain in the range.
  let rows = try database.rows("""
    SELECT m.ROWID AS id, m.text AS body, m.attributedBody AS archived, m.date AS at, m.is_from_me AS mine,
      m.item_type AS kind, m.cache_has_attachments AS attached, h.id AS sender
    FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
    WHERE \(conditions.joined(separator: " AND ")) ORDER BY \(when) DESC, m.ROWID DESC LIMIT \(count + 1)
    """, bindings)
  let attachmentsReadable = (try? database.requireColumns(attachmentColumns)) != nil
  let messages = try rows.prefix(count).reversed().map { row -> JSON in
    var item: JSON = ["id": int(row["id"]) ?? 0, "time": seconds(row["at"]).map { timeText(Date(timeIntervalSinceReferenceDate: $0)) } ?? ""]
    item["from"] = int(row["mine"]) == 1 ? "me" : text(row["sender"]) ?? "unknown"
    if int(row["mine"]) != 1, let sender = person(text(row["sender"]), contacts) { item["from_name"] = sender.name }
    // Item types other than 0 are events in the chat, such as a renamed group or someone joining.
    if let kind = int(row["kind"]), kind != 0 { item["event"] = kind }
    if let body = text(row["body"]) {
      item["text"] = body
    } else if let archived = (row["archived"] ?? nil) as? Data, !archived.isEmpty {
      if let decoded = typedstreamText(archived) { item["text"] = decoded } else { item["text_unreadable"] = true }
    }
    if int(row["attached"]) == 1, attachmentsReadable, let id = int(row["id"]) {
      item["attachments"] = try database.rows("""
        SELECT a.transfer_name AS name, a.mime_type AS type FROM message_attachment_join x JOIN attachment a ON a.ROWID = x.attachment_id
        WHERE x.message_id = ?1 ORDER BY a.ROWID
        """, [id]).map { ["name": text($0["name"]) ?? "", "type": text($0["type"]) ?? ""] as JSON }
    }
    return item
  }
  return ["chat": ["id": found.id, "name": found.name], "messages": messages, "earlier": rows.count > count]
}

// Copies an attachment out of Messages' folder, which macOS keeps from other apps, so the agent can open it.
let messagesSaveAttachment = Operation(
  name: "save_attachment", summary: "Copy a message's attachment to a new temporary file and give its path", effect: .reads,
  arguments: [
    Argument(name: "message", kind: .integer, required: true, description: "Message id from read_chat, of a message with attachments", minimum: 1),
    Argument(name: "index", kind: .integer, required: false, description: "Which of its attachments, from 0; default 0", minimum: 0),
  ]
) { arguments in
  let database = try openMessagesDatabase()
  _ = try database.requireColumns(attachmentColumns)
  let id = arguments["message"] as? Int ?? 0
  let rows = try database.rows("""
    SELECT a.filename AS path FROM message_attachment_join x JOIN attachment a ON a.ROWID = x.attachment_id
    WHERE x.message_id = ?1 ORDER BY a.ROWID
    """, [id])
  let index = arguments["index"] as? Int ?? 0
  guard index < rows.count, let stored = text(rows[index]["path"]) else {
    throw HelperError(code: "not_found", message: rows.isEmpty ? "Message \(id) has no attachment." : "Message \(id) has \(rows.count == 1 ? "one attachment" : "\(rows.count) attachments"); index counts from 0.")
  }
  // Stored paths start with ~; one that leads out of Messages' attachments folder is refused.
  let source = URL(fileURLWithPath: (stored as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
  let folder = URL(fileURLWithPath: attachmentsFolder).resolvingSymlinksInPath().path + "/"
  guard source.path.hasPrefix(folder) else {
    throw HelperError(code: "not_found", message: "Message \(id)'s attachment is outside Messages' folder.")
  }
  guard (try? source.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
    throw HelperError(code: "not_found", message: "Message \(id)'s attachment is not on this Mac; Messages downloads it when the user opens it.")
  }
  let destination = try newCopyFolder(.messagesAttachments).appendingPathComponent(source.lastPathComponent)
  do {
    try FileManager.default.copyItem(at: source, to: destination)
  } catch {
    throw HelperError(code: "action_failed", message: "The attachment could not be copied: \(error.localizedDescription)")
  }
  return ["message": id, "path": destination.path]
}
