// WhatsApp through its own database on this Mac, read-only, so reading a chat needs no window, no scrolling
// and no running app. macOS guards the files as another app's data: the WhatsApp grant on the Setup tab.
// The database format is WhatsApp's own and not documented; a format this code does not know fails with
// unsupported_format instead of guessing, and the window still works then.

import Foundation

let whatsAppBundleId = "net.whatsapp.WhatsApp"
private let container = NSHomeDirectory() + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"
let whatsAppDatabasePath = container + "/ChatStorage.sqlite"
// Attachment paths in the database are relative to this folder.
private let mediaFolder = container + "/Message"

private let defaultMessages = 50
private let maxMessages = 500

// The tables and columns the operations read. A database without them is a format this code does not know.
private let requiredColumns: [String: Set<String>] = [
  "ZWACHATSESSION": ["Z_PK", "ZCONTACTJID", "ZPARTNERNAME", "ZLASTMESSAGEDATE"],
  "ZWAMESSAGE": ["Z_PK", "ZCHATSESSION", "ZISFROMME", "ZMESSAGEDATE", "ZTEXT", "ZMESSAGETYPE"],
]

private func openDatabase() throws -> (ReadOnlyDatabase, [String: Set<String>]) {
  let database = try ReadOnlyDatabase(path: whatsAppDatabasePath, appName: "WhatsApp")
  let found = try database.requireColumns(requiredColumns, optional: ["ZWAGROUPMEMBER", "ZWAMEDIAITEM", "ZWAPROFILEPUSHNAME"])
  return (database, found)
}

// MARK: Values

// WhatsApp stores times as seconds since 2001-01-01, as Core Data does.
private func time(_ value: Any??) -> String? {
  guard let value = value ?? nil else { return nil }
  let seconds: Double? = (value as? Double) ?? (value as? Int64).map(Double.init)
  return seconds.map { timeText(Date(timeIntervalSinceReferenceDate: $0)) }
}

private func referenceSeconds(_ arguments: JSON, _ key: String) throws -> Double? {
  guard let text = optionalString(arguments, key) else { return nil }
  return try moment(text, key: key).date.timeIntervalSinceReferenceDate
}

private func int(_ value: Any??) -> Int64? { (value ?? nil) as? Int64 }
// WhatsApp starts some names with a direction mark, which would only get in the way of matching them.
private func name(_ value: Any??) -> String? {
  text(value)?.trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}\u{200F}"))
}
private func text(_ value: Any??) -> String? {
  guard let text = (value ?? nil) as? String, !text.isEmpty else { return nil }
  return text
}

// The message types WhatsApp's database is known to use; others show their number.
private let messageKinds: [Int64: String] = [
  0: "text", 1: "photo", 2: "video", 3: "audio", 4: "contact", 5: "location", 6: "system", 7: "link", 8: "document",
  11: "gif", 14: "deleted", 15: "sticker",
]

// Group chats have ids ending in @g.us.
private func isGroup(_ jid: String?) -> Bool { jid?.hasSuffix("@g.us") ?? false }

// MARK: Operations

private let listChats = Operation(
  name: "list_chats", summary: "List chats, latest first, with their ids, names and last message time", effect: .reads,
  arguments: [Argument(name: "query", kind: .string, required: false, description: "Only chats whose name or id contains this, ignoring case"), limitArgument]
) { arguments in
  let (database, columns) = try openDatabase()
  let session = columns["ZWACHATSESSION"] ?? []
  let extras = ["ZUNREADCOUNT", "ZARCHIVED", "ZREMOVED"].filter(session.contains)
  // Removed chats stay in the database and are left out; chats without any message yet too, and the status
  // updates, which WhatsApp keeps as a chat of its own.
  let removed = (session.contains("ZREMOVED") ? " AND IFNULL(ZREMOVED, 0) = 0" : "") + " AND ZCONTACTJID NOT LIKE '%@status'"
  let query = optionalString(arguments, "query").map { "%\($0)%" }
  let filter = query == nil ? "" : " AND (ZPARTNERNAME LIKE ?1 OR ZCONTACTJID LIKE ?1)"
  let sql = "SELECT ZCONTACTJID, ZPARTNERNAME, ZLASTMESSAGEDATE\(extras.map { ", " + $0 }.joined()) FROM ZWACHATSESSION"
    + " WHERE ZLASTMESSAGEDATE IS NOT NULL\(removed)\(filter) ORDER BY ZLASTMESSAGEDATE DESC"
  let rows = try database.rows(sql, query.map { [$0] } ?? [])
  let chats = rows.prefix(limit(arguments)).map { row -> JSON in
    var chat: JSON = ["id": text(row["ZCONTACTJID"]) ?? "", "name": name(row["ZPARTNERNAME"]) ?? "", "group": isGroup(text(row["ZCONTACTJID"]))]
    if let last = time(row["ZLASTMESSAGEDATE"]) { chat["last_message"] = last }
    if let unread = int(row["ZUNREADCOUNT"]), unread > 0 { chat["unread"] = unread }
    if int(row["ZARCHIVED"]) == 1 { chat["archived"] = true }
    return chat
  }
  return ["total": rows.count, "has_more": rows.count > chats.count, "chats": chats]
}

// A chat by its id, or by its name when exactly one chat has it.
private func chatKey(_ database: ReadOnlyDatabase, _ wanted: String) throws -> (key: Int64, id: String, name: String) {
  // Names are compared without their direction marks and case, which SQL cannot do.
  let rows = try database.rows("SELECT Z_PK, ZCONTACTJID, ZPARTNERNAME FROM ZWACHATSESSION")
  let exact = rows.filter { text($0["ZCONTACTJID"]) == wanted }
  let chosen = exact.isEmpty ? rows.filter { name($0["ZPARTNERNAME"])?.caseInsensitiveCompare(wanted) == .orderedSame } : exact
  guard let row = chosen.first, let key = int(row["Z_PK"]) else {
    throw HelperError(code: "not_found", message: "No chat has the id or name \(wanted). Use list_chats with query.")
  }
  guard chosen.count == 1 else {
    throw HelperError(code: "ambiguous", message: "\(chosen.count) chats are named \(wanted). Use the id from list_chats.")
  }
  return (key, text(row["ZCONTACTJID"]) ?? "", name(row["ZPARTNERNAME"]) ?? "")
}

private let readChat = Operation(
  name: "read_chat", summary: "Read a chat's messages, oldest first: the latest ones, or those in a time range", effect: .reads,
  arguments: [
    Argument(name: "chat", kind: .string, required: true, description: "Chat id from list_chats, or the chat's exact name"),
    Argument(name: "since", kind: .string, required: false, description: "Only messages from this time on: an ISO 8601 date or time, such as 2026-11-06 or 2026-11-06T08:00"),
    Argument(name: "until", kind: .string, required: false, description: "Only messages before this time"),
    Argument(name: "before", kind: .integer, required: false, description: "Only messages older than this message id; pass the first message's id to read earlier ones", minimum: 1),
    Argument(name: "limit", kind: .integer, required: false, description: "Most messages to return, the latest in the range; default \(defaultMessages)", minimum: 1, maximum: maxMessages),
  ]
) { arguments in
  let (database, columns) = try openDatabase()
  let chat = try chatKey(database, try string(arguments, "chat"))
  let message = columns["ZWAMESSAGE"] ?? []
  let member = columns["ZWAGROUPMEMBER"] ?? []
  let media = columns["ZWAMEDIAITEM"] ?? []
  let pushNames = columns["ZWAPROFILEPUSHNAME"] ?? []
  var select = "m.Z_PK AS id, m.ZISFROMME AS mine, m.ZMESSAGEDATE AS at, m.ZTEXT AS body, m.ZMESSAGETYPE AS kind"
  var joins = ""
  if message.contains("ZFROMJID") { select += ", m.ZFROMJID AS from_jid" }
  if message.contains("ZGROUPMEMBER"), member.isSuperset(of: ["Z_PK", "ZMEMBERJID"]) {
    joins += " LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = m.ZGROUPMEMBER"
    select += ", g.ZMEMBERJID AS member_jid" + (member.contains("ZCONTACTNAME") ? ", g.ZCONTACTNAME AS member_name" : "")
  }
  if message.contains("ZMEDIAITEM"), media.isSuperset(of: ["Z_PK", "ZMEDIALOCALPATH"]) {
    joins += " LEFT JOIN ZWAMEDIAITEM a ON a.Z_PK = m.ZMEDIAITEM"
    select += ", a.ZMEDIALOCALPATH AS media_path" + (media.contains("ZTITLE") ? ", a.ZTITLE AS media_title" : "")
  }
  var conditions = ["m.ZCHATSESSION = ?1"]
  var bindings: [Any?] = [Int(chat.key)]
  if let since = try referenceSeconds(arguments, "since") {
    bindings.append(since)
    conditions.append("m.ZMESSAGEDATE >= ?\(bindings.count)")
  }
  if let until = try referenceSeconds(arguments, "until") {
    bindings.append(until)
    conditions.append("m.ZMESSAGEDATE < ?\(bindings.count)")
  }
  // By date, then id, as the messages are ordered, so messages sharing a time are neither skipped nor repeated.
  if let before = arguments["before"] as? Int {
    let rows = try database.rows("SELECT ZMESSAGEDATE AS at FROM ZWAMESSAGE WHERE Z_PK = ?1 AND ZCHATSESSION = ?2", [before, Int(chat.key)])
    guard let at = rows.first?["at"] ?? nil else {
      throw HelperError(code: "not_found", message: "Message \(before) is not in this chat.")
    }
    bindings.append(at as? Double ?? (at as? Int64).map(Double.init))
    let date = bindings.count
    bindings.append(before)
    conditions.append("(m.ZMESSAGEDATE < ?\(date) OR (m.ZMESSAGEDATE = ?\(date) AND m.Z_PK < ?\(bindings.count)))")
  }
  let count = arguments["limit"] as? Int ?? defaultMessages
  // One more than asked, to tell whether earlier messages remain in the range.
  let rows = try database.rows(
    "SELECT \(select) FROM ZWAMESSAGE m\(joins) WHERE \(conditions.joined(separator: " AND ")) ORDER BY m.ZMESSAGEDATE DESC, m.Z_PK DESC LIMIT \(count + 1)",
    bindings)
  // A group member's name comes from the user's contacts, else from the name they gave themselves.
  var names: [String: String] = [:]
  if pushNames.isSuperset(of: ["ZJID", "ZPUSHNAME"]) {
    for row in try database.rows("SELECT ZJID, ZPUSHNAME FROM ZWAPROFILEPUSHNAME") {
      if let jid = text(row["ZJID"]), let name = text(row["ZPUSHNAME"]) { names[jid] = name }
    }
  }
  let messages = rows.prefix(count).reversed().map { row -> JSON in
    var item: JSON = ["id": int(row["id"]) ?? 0, "time": time(row["at"]) ?? ""]
    if int(row["mine"]) == 1 {
      item["from"] = "me"
    } else if isGroup(chat.id) {
      let jid = text(row["member_jid"]) ?? text(row["from_jid"])
      item["from"] = name(row["member_name"]) ?? jid.flatMap { names[$0] } ?? jid ?? "unknown"
    } else {
      item["from"] = chat.name.isEmpty ? chat.id : chat.name
    }
    let kind = int(row["kind"]) ?? 0
    item["type"] = messageKinds[kind] ?? "type \(kind)"
    let type = item["type"] as? String
    // A document's text is its file name; an attachment's caption is kept with the attachment.
    if let body = text(row["body"]) { item[type == "document" ? "file" : "text"] = body }
    if text(row["media_path"]) != nil {
      item["media"] = true
      if let caption = text(row["media_title"]) { item["caption"] = caption }
    }
    return item
  }
  return ["chat": ["id": chat.id, "name": chat.name], "messages": messages, "earlier": rows.count > count]
}

// Copies an attachment out of WhatsApp's folder, which macOS keeps from other apps, so the agent can open it.
private let saveMedia = Operation(
  name: "save_media", summary: "Copy a message's photo, video, audio or document to a temporary file and give its path", effect: .reads,
  arguments: [Argument(name: "message", kind: .integer, required: true, description: "Message id from read_chat, of a message with media: true", minimum: 1)]
) { arguments in
  let (database, columns) = try openDatabase()
  guard (columns["ZWAMESSAGE"] ?? []).contains("ZMEDIAITEM"), (columns["ZWAMEDIAITEM"] ?? []).isSuperset(of: ["Z_PK", "ZMEDIALOCALPATH"]) else {
    throw HelperError(code: "unsupported_format", message: "This WhatsApp version keeps attachments in a format Backstage does not know.")
  }
  let id = arguments["message"] as? Int ?? 0
  let rows = try database.rows("SELECT a.ZMEDIALOCALPATH AS path FROM ZWAMESSAGE m JOIN ZWAMEDIAITEM a ON a.Z_PK = m.ZMEDIAITEM WHERE m.Z_PK = ?1", [id])
  guard let relative = rows.first.flatMap({ text($0["path"]) }) else {
    throw HelperError(code: "not_found", message: "Message \(id) has no attachment.")
  }
  // The path comes from the database; one that leads out of WhatsApp's folder is refused.
  let source = URL(fileURLWithPath: mediaFolder + "/" + relative).standardizedFileURL.resolvingSymlinksInPath()
  guard source.path.hasPrefix(URL(fileURLWithPath: mediaFolder).resolvingSymlinksInPath().path + "/") else {
    throw HelperError(code: "not_found", message: "Message \(id)'s attachment is outside WhatsApp's folder.")
  }
  guard FileManager.default.fileExists(atPath: source.path) else {
    throw HelperError(code: "not_found", message: "Message \(id)'s attachment is not on this Mac; WhatsApp downloads it when the user opens it.")
  }
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("whatsapp-media", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let destination = folder.appendingPathComponent("\(id)-\(source.lastPathComponent)")
  try? FileManager.default.removeItem(at: destination)
  do {
    try FileManager.default.copyItem(at: source, to: destination)
  } catch {
    throw HelperError(code: "action_failed", message: "The attachment could not be copied: \(error.localizedDescription)")
  }
  return ["message": id, "path": destination.path]
}

let whatsAppKnowledge = AppKnowledge(
  bundleId: whatsAppBundleId, name: "WhatsApp", summary: "Read chats and messages from WhatsApp's data on this Mac, without its window",
  access: "Read your chats",
  hints: [
    "In the window, each message is a static text whose label holds its text, time and sender; read_text gives a long one whole.",
  ],
  pitfalls: [
    "Operations read what WhatsApp has stored on this Mac: messages it has not synced yet do not show.",
    "Sending is not supported here; it goes through the window.",
  ],
  operations: [listChats, readChat, saveMedia])
