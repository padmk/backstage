// Messages' and WhatsApp's chats read from databases made here in their formats, with the columns the readers need.

@testable import App
import Foundation
import Testing

private let messagesTables = """
  CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT);
  CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
  CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER,
    handle_id INTEGER, associated_message_type INTEGER, item_type INTEGER, cache_has_attachments INTEGER);
  CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
  CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
  """

// One person over iMessage and SMS (chats 1 and 2), two groups that share a name (3 and 4) and two groups that share
// an id (5 and 6). Message 1 keeps its time in seconds, the rest in nanoseconds; 4, 5 and 6 share a time.
private let messagesRows = """
  INSERT INTO handle VALUES (1, '+48111'), (2, '+48222'), (3, '+48333');
  INSERT INTO chat VALUES (1, 'iMessage;-;+48111', '+48111', NULL), (2, 'SMS;-;+48111', '+48111', ''),
    (3, 'iMessage;+;chat1', 'chat1', 'Family'), (4, 'iMessage;+;chat2', 'chat2', 'family'),
    (5, 'iMessage;+;chat7', 'chat7', 'Team'), (6, 'SMS;+;chat7', 'chat7', 'Team B');
  INSERT INTO chat_handle_join VALUES (1, 1), (2, 1), (3, 2), (3, 3), (4, 2), (4, 3), (5, 2), (5, 3), (6, 2), (6, 3);
  INSERT INTO message VALUES
    (1, 'first', NULL, 700000000, 0, 1, 0, 0, 0),
    (2, 'second', NULL, 700000100000000000, 1, 0, 0, 0, 0),
    (3, 'by SMS', NULL, 700000050000000000, 0, 1, 0, 0, 0),
    (4, 'same time a', NULL, 700000200000000000, 0, 1, 0, 0, 0),
    (5, 'same time b', NULL, 700000200000000000, 1, 0, 0, 0, 0),
    (6, 'same time c', NULL, 700000200000000000, 0, 1, 0, 0, 0),
    (7, NULL, NULL, 700000300000000000, 0, 1, 2000, 0, 0),
    (8, 'in a group', NULL, 700000300000000000, 0, 2, 0, 0, 0);
  INSERT INTO chat_message_join VALUES (1, 1), (1, 2), (2, 3), (1, 4), (2, 5), (1, 6), (1, 7), (3, 8);
  """

private func messages(_ result: JSON) -> [JSON] { result["messages"] as? [JSON] ?? [] }
private func ids(_ result: JSON) -> [Int64] { messages(result).compactMap { $0["id"] as? Int64 } }

@Suite struct MessagesDatabaseTests {
  // A new instance for each test, so each reads a database of its own, kept until the test ends.
  private let folder: TemporaryFolder
  private let written: TestDatabase
  private let database: ReadOnlyDatabase

  init() throws {
    folder = try TemporaryFolder()
    written = try TestDatabase(in: folder, messagesTables + messagesRows)
    database = try openMessagesDatabase(at: written.path)
  }

  @Test func onePersonsChatsOverSeveralServicesReadAsOneConversation() throws {
    let result = try readMessagesChat(database, ["chat": "+48111"])
    #expect(ids(result) == [1, 3, 2, 4, 5, 6])
    #expect((result["chat"] as? JSON)?["id"] as? String == "+48111")
    #expect(ids(try readMessagesChat(database, ["chat": "SMS;-;+48111"])) == [3, 5])
  }

  @Test func chatsOfDifferentPeopleStayAmbiguous() throws {
    helperError("ambiguous") { try readMessagesChat(database, ["chat": "family"]) }
    helperError("ambiguous") { try readMessagesChat(database, ["chat": "chat7"]) }
    helperError("not_found") { try readMessagesChat(database, ["chat": "+48999"]) }
    #expect(ids(try readMessagesChat(database, ["chat": "Team B"])) == [])
  }

  @Test func timesInSecondsAndNanosecondsAreTheSameClock() throws {
    let read = messages(try readMessagesChat(database, ["chat": "+48111"]))
    #expect(instant(read.first?["time"]) == Date(timeIntervalSinceReferenceDate: 700_000_000))
    #expect(instant(read.first { $0["id"] as? Int64 == 2 }?["time"]) == Date(timeIntervalSinceReferenceDate: 700_000_100))
    let since = timeText(Date(timeIntervalSinceReferenceDate: 700_000_050))
    let until = timeText(Date(timeIntervalSinceReferenceDate: 700_000_200))
    #expect(ids(try readMessagesChat(database, ["chat": "+48111", "since": since, "until": until])) == [3, 2])
  }

  @Test func pagingBackSkipsAndRepeatsNothingWhenTimesAreEqual() throws {
    var pages: [[Int64]] = []
    var arguments: JSON = ["chat": "+48111", "limit": 2]
    while true {
      let result = try readMessagesChat(database, arguments)
      pages.append(ids(result))
      guard result["earlier"] as? Bool == true, let first = ids(result).first else { break }
      arguments["before"] = Int(first)
    }
    #expect(pages == [[5, 6], [2, 4], [1, 3]])
    helperError("not_found") { try readMessagesChat(database, ["chat": "+48111", "before": 8]) }
  }

  @Test func aBodyArchivedByMessagesIsRead() throws {
    var archived: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8) + [0x84, 0x84, 0x08] + Array("NSString".utf8)
    archived += [0x01, 0x94, 0x84, 0x01, 0x2B, 0x08] + Array("archived".utf8) + [0x86]
    try written.insert("INSERT INTO message VALUES (9, NULL, ?1, 700000400000000000, 0, 1, 0, 0, 0)", blob: Data(archived))
    try written.run("INSERT INTO chat_message_join VALUES (1, 9);")
    let read = messages(try readMessagesChat(database, ["chat": "iMessage;-;+48111"]))
    #expect(read.last?["text"] as? String == "archived")
  }

  @Test func aDatabaseWithoutAColumnItReadsIsAnUnknownFormat() throws {
    let other = try TestDatabase(in: folder, messagesTables.replacingOccurrences(of: "attributedBody BLOB, ", with: ""))
    helperError("unsupported_format") { try openMessagesDatabase(at: other.path) }
  }
}

private let whatsAppTables = """
  CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZCONTACTJID TEXT, ZPARTNERNAME TEXT, ZLASTMESSAGEDATE REAL);
  CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZISFROMME INTEGER, ZMESSAGEDATE REAL, ZTEXT TEXT,
    ZMESSAGETYPE INTEGER);
  """

private let whatsAppRows = #"""
  INSERT INTO ZWACHATSESSION VALUES (1, '1@s.whatsapp.net', '100% sure', 700000500), (2, '2@s.whatsapp.net', '100 sure', 700000400),
    (3, '3@s.whatsapp.net', 'a_b', 700000300), (4, '4@s.whatsapp.net', 'axb', 700000200),
    (5, '5@s.whatsapp.net', 'c\d', 700000100), (6, '6@s.whatsapp.net', 'cd', 700000000);
  INSERT INTO ZWAMESSAGE VALUES (1, 1, 0, 700000000, 'one', 0), (2, 1, 1, 700000100, 'two', 0), (3, 1, 0, 700000100, 'three', 0),
    (4, 1, 1, 700000100, 'four', 0), (5, 1, 0, 700000200.5, 'five', 0), (6, 2, 0, 700000100, 'other chat', 0);
  """#

@Suite struct WhatsAppDatabaseTests {
  private let folder: TemporaryFolder
  private let written: TestDatabase
  private let database: WhatsAppDatabase

  init() throws {
    folder = try TemporaryFolder()
    written = try TestDatabase(in: folder, whatsAppTables + whatsAppRows)
    database = try openWhatsAppDatabase(at: written.path)
  }

  @Test func aQueryMatchesPercentUnderscoreAndBackslashLiterally() throws {
    let names = { (query: String) in
      (try whatsAppChatList(database, ["query": query])["chats"] as? [JSON] ?? []).compactMap { $0["name"] as? String }
    }
    #expect(try names("%") == ["100% sure"])
    #expect(try names("_") == ["a_b"])
    #expect(try names("a_b") == ["a_b"])
    #expect(try names(#"\"#) == [#"c\d"#])
    #expect(try names("SURE") == ["100% sure", "100 sure"])
  }

  @Test func pagingBackSkipsAndRepeatsNothingWhenTimesAreEqual() throws {
    var pages: [[Int64]] = []
    var arguments: JSON = ["chat": "1@s.whatsapp.net", "limit": 2]
    while true {
      let result = try whatsAppReadChat(database, arguments)
      pages.append(ids(result))
      guard result["earlier"] as? Bool == true, let first = ids(result).first else { break }
      arguments["before"] = Int(first)
    }
    #expect(pages == [[4, 5], [2, 3], [1]])
    let read = messages(try whatsAppReadChat(database, ["chat": "100% SURE"]))
    #expect(instant(read.first?["time"]) == Date(timeIntervalSinceReferenceDate: 700_000_000))
    let since = timeText(Date(timeIntervalSinceReferenceDate: 700_000_100))
    #expect(ids(try whatsAppReadChat(database, ["chat": "1@s.whatsapp.net", "since": since])) == [2, 3, 4, 5])
  }

  @Test func aDatabaseWithoutAColumnItReadsIsAnUnknownFormat() throws {
    let other = try TestDatabase(in: folder, whatsAppTables.replacingOccurrences(of: ", ZTEXT TEXT", with: ""))
    helperError("unsupported_format") { try openWhatsAppDatabase(at: other.path) }
  }
}
