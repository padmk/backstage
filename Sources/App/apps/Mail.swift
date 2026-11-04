// Mail through its scripting dictionary. Nothing here sends mail: create_draft saves a draft for the user to
// review and send.

import Foundation

private let target = "Mail"
private let maxDays = 90

private let prelude = #"""
  const Mail = Application('Mail');
  const fail = (code, text) => { throw new Error(code + ': ' + text); };
  function mailbox(accountName, mailboxName) {
    const account = Mail.accounts.byName(accountName);
    try { account.name(); } catch (error) { fail('not_found', 'There is no account named ' + accountName + '. Use list_mailboxes.'); }
    const box = account.mailboxes.byName(mailboxName);
    try { box.name(); } catch (error) { fail('not_found', accountName + ' has no mailbox named ' + mailboxName + '. Use list_mailboxes.'); }
    return box;
  }
  function message(args) {
    const found = mailbox(args.account, args.mailbox).messages.byId(args.id);
    try { found.subject(); } catch (error) { fail('not_found', 'There is no message ' + args.id + ' in ' + args.mailbox + '.'); }
    return found;
  }
  function summary(found) {
    const box = found.mailbox();
    return { id: found.id(), account: box.account().name(), mailbox: box.name(), subject: found.subject(), from: found.sender(),
      received: found.dateReceived(), read: found.readStatus() };
  }
  const addresses = (text) => (text || '').split(',').map((part) => part.trim()).filter((part) => part.length);
  """#

private func script(_ body: String) -> String { prelude + body }

private let messageArguments = [
  Argument(name: "account", kind: .string, required: true, description: "Account name, from search or list_mailboxes"),
  Argument(name: "mailbox", kind: .string, required: true, description: "Mailbox name, from search or list_mailboxes"),
  Argument(name: "id", kind: .integer, required: true, description: "Message id from search"),
]

private let listMailboxes = Operation(
  name: "list_mailboxes", summary: "List accounts and their mailboxes with unread counts", effect: .reads, arguments: []
) { _ in
  try dictionary(runScript(script(#"""
    return { accounts: Mail.accounts().map((account) => ({
      name: account.name(), enabled: account.enabled(),
      mailboxes: account.mailboxes().map((box) => ({ name: box.name(), unread: box.unreadCount() })),
    })) };
    """#), target: target, timeout: 60), from: target)
}

private let search = Operation(
  name: "search", summary: "Find recent messages by subject or sender, newest first", effect: .reads,
  arguments: [
    Argument(name: "query", kind: .string, required: false, description: "Text in the subject or the sender; default every message"),
    Argument(name: "account", kind: .string, required: false, description: "Account name; default the inboxes of every account"),
    Argument(name: "mailbox", kind: .string, required: false, description: "Mailbox name in that account; default its INBOX"),
    Argument(name: "unread_only", kind: .boolean, required: false, description: "Only unread messages; default false"),
    Argument(name: "days", kind: .integer, required: false, description: "How many days back; default 7", minimum: 1, maximum: maxDays),
    limitArgument,
  ]
) { arguments in
  if arguments["mailbox"] != nil, arguments["account"] == nil {
    throw HelperError(code: "invalid_arguments", message: "Give account together with mailbox.")
  }
  var given = arguments
  given["limit"] = limit(arguments)
  given["days"] = arguments["days"] as? Int ?? 7
  return try dictionary(runScript(script(#"""
    const scope = args.account ? mailbox(args.account, args.mailbox || 'INBOX') : Mail.inbox;
    const recent = { dateReceived: { _greaterThan: new Date(Date.now() - args.days * 86400000) } };
    const base = args.unread_only ? { _and: [recent, { readStatus: false }] } : recent;
    const sets = args.query
      ? [{ subject: { _contains: args.query } }, { sender: { _contains: args.query } }].map((match) => scope.messages.whose({ _and: [base, match] }))
      : [scope.messages.whose(base)];
    const found = [];
    const seen = new Set();
    for (const set of sets) {
      const messages = set();
      const dates = set.dateReceived();
      messages.forEach((item, index) => {
        const key = item.id();
        if (!seen.has(key)) { seen.add(key); found.push([item, dates[index]]); }
      });
    }
    found.sort((a, b) => b[1] - a[1]);
    return { total: found.length, messages: found.slice(0, args.limit).map(([item]) => summary(item)) };
    """#), arguments: given, target: target, timeout: 60), from: target)
}

private let read = Operation(
  name: "read", summary: "Read a message's headers and plain text, leaving its read state as it was", effect: .reads,
  arguments: messageArguments
) { arguments in
  try dictionary(runScript(script(#"""
    const found = message(args);
    const wasRead = found.readStatus();
    const result = summary(found);
    result.to = found.toRecipients().map((item) => item.address());
    result.cc = found.ccRecipients().map((item) => item.address());
    const content = found.content() || '';
    result.text = content.slice(0, 50000);
    if (content.length > 50000) result.text_truncated = true;
    result.attachments = found.mailAttachments().map((item) => item.name());
    if (found.readStatus() !== wasRead) found.readStatus = wasRead;
    result.read = wasRead;
    return result;
    """#), arguments: arguments, target: target), from: target)
}

private let setRead = Operation(
  name: "set_read", summary: "Mark a message read or unread", effect: .changes,
  arguments: messageArguments + [Argument(name: "read", kind: .boolean, required: true, description: "true for read, false for unread")]
) { arguments in
  try dictionary(runScript(script(#"""
    const found = message(args);
    found.readStatus = args.read;
    const result = summary(found);
    result.verified = result.read === args.read;
    return result;
    """#), arguments: arguments, target: target), from: target)
}

private let createDraft = Operation(
  name: "create_draft", summary: "Save a new message as a draft, without sending it", effect: .changes,
  arguments: [
    Argument(name: "to", kind: .string, required: true, description: "Addresses, separated by commas"),
    Argument(name: "subject", kind: .string, required: true, description: "Subject"),
    Argument(name: "body", kind: .string, required: true, description: "Plain text"),
    Argument(name: "cc", kind: .string, required: false, description: "Addresses, separated by commas"),
    Argument(name: "bcc", kind: .string, required: false, description: "Addresses, separated by commas"),
  ]
) { arguments in
  try dictionary(runScript(script(#"""
    const drafts = () => Mail.draftsMailbox.messages.whose({ subject: args.subject }).length;
    const before = drafts();
    const draft = Mail.OutgoingMessage({ subject: args.subject, content: args.body, visible: false });
    Mail.outgoingMessages.push(draft);
    addresses(args.to).forEach((address) => draft.toRecipients.push(Mail.ToRecipient({ address })));
    addresses(args.cc).forEach((address) => draft.ccRecipients.push(Mail.CcRecipient({ address })));
    addresses(args.bcc).forEach((address) => draft.bccRecipients.push(Mail.BccRecipient({ address })));
    draft.save();
    draft.close({ saving: 'yes' });
    // Mail files the draft a moment after saving it.
    let saved = false;
    for (let check = 0; check < 20 && !saved; check++) {
      saved = drafts() > before;
      if (!saved) delay(0.15);
    }
    if (!saved) fail('outcome_unknown', 'Mail did not show the draft in Drafts. Check Drafts before trying again; Mail needs an enabled account to keep drafts.');
    return { subject: args.subject, to: addresses(args.to), verified: true };
    """#), arguments: arguments, target: target), from: target)
}

let mailKnowledge = AppKnowledge(
  bundleId: "com.apple.mail", name: "Mail", scripted: true, summary: "Find and read mail, mark it read, and save drafts",
  access: "Can also read your mail and save drafts through scripting, even while Mail is closed.",
  hints: ["The sidebar lists mailboxes by account; the message list and the message are to its right."],
  pitfalls: [
    "Nothing here sends mail. create_draft saves to Drafts; the user sends it.",
    "search looks at subjects and senders, not message text, and only as far back as days.",
    "Mail starts if it is not running, to answer an operation.",
  ],
  operations: [listMailboxes, search, read, setRead, createDraft])
