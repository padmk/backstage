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

private func openDatabase() throws -> ReadOnlyDatabase {
  let database = try ReadOnlyDatabase(path: messagesDatabasePath, appName: "Messages")
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

// A chat by the id list_chats gives (its guid), else by the one handle or group id it is known by, else by its name;
// more than one match is refused.
private func chat(_ database: ReadOnlyDatabase, _ wanted: String) throws -> (key: Int64, id: String, name: String) {
  let rows = try database.rows("SELECT ROWID, guid, chat_identifier, display_name FROM chat")
  let tiers: [([String: Any?]) -> Bool] = [
    { text($0["guid"]) == wanted },
    { text($0["chat_identifier"]) == wanted },
    { text($0["display_name"])?.caseInsensitiveCompare(wanted) == .orderedSame },
  ]
  for matches in tiers.map({ rows.filter($0) }) where !matches.isEmpty {
    guard matches.count == 1, let row = matches.first, let key = int(row["ROWID"]) else {
      throw HelperError(code: "ambiguous", message: "\(matches.count) chats match \(wanted). Use the id from list_chats.")
    }
    return (key, text(row["guid"]) ?? "", text(row["display_name"]) ?? text(row["chat_identifier"]) ?? "")
  }
  throw HelperError(code: "not_found", message: "No chat has the id, handle or name \(wanted). Use list_chats.")
}

// The chats as list_chats gives them, latest first, from the database: ids, names, participants' handles and when
// the last message came.
func messagesChatList(query: String?, limit: Int) throws -> JSON {
  let database = try openDatabase()
  let chats = try database.rows("""
    SELECT c.ROWID AS key, c.guid AS id, c.display_name AS name, c.chat_identifier AS identifier,
      (SELECT MAX(m.date) FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id WHERE j.chat_id = c.ROWID) AS last
    FROM chat c ORDER BY last IS NULL, last DESC
    """)
  let participants = try database.rows("""
    SELECT x.chat_id AS chat, h.id AS handle FROM chat_handle_join x JOIN handle h ON h.ROWID = x.handle_id ORDER BY h.ROWID
    """).reduce(into: [Int64: [String]]()) { map, row in
      if let chat = int(row["chat"]), let handle = text(row["handle"]) { map[chat, default: []].append(handle) }
    }
  let wanted = query?.lowercased()
  let described = chats.map { row -> JSON in
    var chat: JSON = ["id": text(row["id"]) ?? "", "name": text(row["name"]) ?? "", "participants": participants[int(row["key"]) ?? -1] ?? []]
    if let last = seconds(row["last"]) { chat["last_message"] = timeText(Date(timeIntervalSinceReferenceDate: last)) }
    if let identifier = text(row["identifier"]) { chat["handle"] = identifier }
    return chat
  }.filter { chat in
    guard let wanted else { return true }
    let names = [chat["name"] as? String ?? "", chat["handle"] as? String ?? ""] + (chat["participants"] as? [String] ?? [])
    return names.contains { $0.lowercased().contains(wanted) }
  }
  let shown = Array(described.prefix(limit))
  return ["total": described.count, "has_more": described.count > shown.count, "chats": shown, "source": "database"]
}

let messagesReadChat = Operation(
  name: "read_chat", summary: "Read a conversation's messages, oldest first, from Messages' data on this Mac", effect: .reads,
  arguments: [
    Argument(name: "chat", kind: .string, required: true, description: "Chat id from list_chats, a phone number or email address of a one-to-one chat, or a group's name"),
    Argument(name: "since", kind: .string, required: false, description: "Only messages from this time on: an ISO 8601 date or time"),
    Argument(name: "until", kind: .string, required: false, description: "Only messages before this time"),
    Argument(name: "before", kind: .integer, required: false, description: "Only messages older than this message id; pass the first message's id to read earlier ones", minimum: 1),
    Argument(name: "limit", kind: .integer, required: false, description: "Most messages to return, the latest in the range; default \(defaultMessages)", minimum: 1, maximum: maxMessages),
  ]
) { arguments in
  let database = try openDatabase()
  let found = try chat(database, try string(arguments, "chat"))
  // Reactions and other messages that point at another one are left out; they are not messages of their own.
  var conditions = ["j.chat_id = ?1", "IFNULL(m.associated_message_type, 0) = 0"]
  var bindings: [Any?] = [found.key]
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
    let rows = try database.rows("SELECT \(when) AS at FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID WHERE m.ROWID = ?1 AND j.chat_id = ?2", [before, found.key])
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
    FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID LEFT JOIN handle h ON h.ROWID = m.handle_id
    WHERE \(conditions.joined(separator: " AND ")) ORDER BY \(when) DESC, m.ROWID DESC LIMIT \(count + 1)
    """, bindings)
  let attachmentsReadable = (try? database.requireColumns(attachmentColumns)) != nil
  let messages = try rows.prefix(count).reversed().map { row -> JSON in
    var item: JSON = ["id": int(row["id"]) ?? 0, "time": seconds(row["at"]).map { timeText(Date(timeIntervalSinceReferenceDate: $0)) } ?? ""]
    item["from"] = int(row["mine"]) == 1 ? "me" : text(row["sender"]) ?? "unknown"
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
  let database = try openDatabase()
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
  let destination = try newCopyFolder("messages-attachments").appendingPathComponent(source.lastPathComponent)
  do {
    try FileManager.default.copyItem(at: source, to: destination)
  } catch {
    throw HelperError(code: "action_failed", message: "The attachment could not be copied: \(error.localizedDescription)")
  }
  return ["message": id, "path": destination.path]
}
