// Messages through its scripting dictionary, which can list chats and send but cannot read messages. Reading
// a conversation goes through the window, so Backstage never needs Full Disk Access for the message database.

import AppKit

private let target = "Messages"

private let listChats = Operation(
  name: "list_chats", summary: "List chats with their ids, names and participants' handles", effect: .reads, arguments: [limitArgument]
) { arguments in
  try dictionary(runScript(#"""
    const Messages = Application('Messages');
    const chats = Messages.chats();
    // Some chats, such as one-to-one ones, have no name, and some details are missing; each is read on its own.
    const read = (get, fallback) => { try { return get(); } catch (error) { return fallback; } };
    return { total: chats.length, chats: chats.slice(0, args.limit).map((chat) => ({
      id: chat.id(),
      name: read(() => chat.name(), '') || '',
      service: read(() => chat.account().serviceType(), ''),
      participants: read(() => chat.participants().map((person) => person.handle()), []),
    })) };
    """#, arguments: ["limit": limit(arguments)], target: target), from: target)
}

// A chat id from list_chats contains semicolons ("iMessage;-;+15555550100"); anything else is a handle.
private let sendScript = """
  on run argv
    set destination to item 1 of argv
    set message to item 2 of argv
    tell application "Messages"
      if destination contains ";" then
        send message to chat id destination
      else
        send message to participant destination of (first account whose service type = iMessage)
      end if
    end tell
    return "sent"
  end run
  """

private let send = Operation(
  name: "send", summary: "Send a text message over iMessage to a chat or a handle. It cannot be undone", effect: .changes,
  arguments: [
    Argument(name: "to", kind: .string, required: true, description: "Chat id from list_chats, or a phone number or email address registered with iMessage"),
    Argument(name: "text", kind: .string, required: true, description: "The message"),
  ]
) { arguments in
  let destination = try string(arguments, "to").trimmingCharacters(in: .whitespaces)
  let text = try string(arguments, "text")
  guard !destination.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    throw HelperError(code: "invalid_arguments", message: "to and text must not be empty.")
  }
  let before = chatLabels(containing: text)
  _ = try runAppleScript(sendScript, arguments: [destination, text], target: target)
  // Scripting cannot read messages, but each chat in the window's list is labelled with its latest message, so
  // a new label holding the text shows the message was sent.
  // Without a list read before sending, an older label with the same text could pass for the new one.
  var shown = false
  let deadline = Date().addingTimeInterval(sentCheckSeconds)
  while let before, let after = chatLabels(containing: text), Date() < deadline {
    if !after.subtracting(before).isEmpty {
      shown = true
      break
    }
    sleep(seconds: 0.2)
  }
  var result: JSON = ["to": destination, "sent": true, "verified": shown]
  if !shown { result["check"] = "The chat list did not show the message. Read the conversation with get_window_state on Messages before sending again." }
  return result
}

private let sentCheckSeconds = 3.0
private let maxLabelSearch = 3000

// The labels of chats in Messages' window that contain the text's first line, or nil when no window can be read.
private func chatLabels(containing text: String) -> Set<String>? {
  guard AXIsProcessTrusted(),
    let app = onMain({ NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first { !$0.isTerminated } })
  else { return nil }
  let window = windows(of: AXUIElementCreateApplication(app.processIdentifier)).first
  guard let window else { return nil }
  let wanted = String((text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text).prefix(40))
  var found = Set<String>()
  var queue = [window]
  var visited = 0
  while !queue.isEmpty, visited < maxLabelSearch {
    let element = queue.removeFirst()
    visited += 1
    if stringAttribute(element, kAXRoleAttribute) == kAXStaticTextRole, let label = stringAttribute(element, kAXDescriptionAttribute), label.contains(wanted) {
      found.insert(label)
    }
    queue += (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
  }
  return found
}

let messagesKnowledge = AppKnowledge(
  bundleId: "com.apple.MobileSMS", name: "Messages", scripted: true, summary: "List chats and send iMessages; read conversations through the window",
  access: "Send messages in your name",
  hints: [
    "Each chat in the sidebar is a static text labelled with its name, unread state, latest message and time; press opens it. Its own actions include Pin, Mark as Unread, Hide Alerts, Open in New Window and Delete.",
  ],
  pitfalls: [
    "A sent message cannot be taken back. Confirm the recipient and the text with the user before send.",
    "Scripting cannot read messages; read a conversation through the window instead.",
    "send to a handle uses iMessage; a number without iMessage fails. Use a chat id from list_chats for SMS chats.",
  ],
  operations: [listChats, send])
