// Notes through its scripting dictionary. Bodies are HTML inside Notes; text from the agent is escaped and
// added as paragraphs, so it never becomes markup.

import Foundation

private let target = "Notes"

// Shared by the scripts: finding a folder or note, and turning plain text into Notes paragraphs.
private let prelude = #"""
  const Notes = Application('Notes');
  const fail = (code, text) => { throw new Error(code + ': ' + text); };
  const escape = (text) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const paragraphs = (text) => text.split(/\r\n|\r|\n/).map((line) => line.length ? '<div>' + escape(line) + '</div>' : '<div><br></div>').join('');
  // Text as Notes keeps it, for comparing what was written with what is read back: HTML turns each run of spaces
  // and tabs into one space, and trailing empty lines carry no text.
  const plain = (text) => text.split(/\r\n|\r|\n/).map((line) => line.replace(/[ \t\u00a0]+/g, ' ').trim()).join('\n').replace(/\s+$/, '');
  function folderNamed(query) {
    if (query.startsWith('x-coredata://')) {
      const folder = Notes.folders.byId(query);
      try { folder.name(); } catch (error) { fail('not_found', 'There is no folder with id ' + query + '.'); }
      return folder;
    }
    const matches = Notes.folders.whose({ name: query });
    const count = matches.length;
    if (count === 0) fail('not_found', 'There is no folder named ' + query + '. Use list_folders.');
    if (count > 1) fail('ambiguous', 'Several folders are named ' + query + '. Give its id from list_folders.');
    return matches[0];
  }
  function noteWithId(id) {
    const note = Notes.notes.byId(id);
    try { note.name(); } catch (error) { fail('not_found', 'There is no note with id ' + id + '.'); }
    if (note.passwordProtected()) fail('not_allowed', 'This note is locked.');
    return note;
  }
  function summary(note) {
    let folder = '';
    try { folder = note.container().name(); } catch (error) {}
    return { id: note.id(), name: note.name(), folder: folder, modified: note.modificationDate() };
  }
  """#

private func script(_ body: String) -> String { prelude + body }

private let listFolders = Operation(
  name: "list_folders", summary: "List folders in every account, with their ids and note counts", effect: .reads, arguments: []
) { _ in
  try dictionary(runScript(script(#"""
    const defaultFolder = Notes.defaultAccount().defaultFolder().id();
    return { folders: Notes.accounts().flatMap((account) => account.folders().map((folder) => ({
      id: folder.id(), name: folder.name(), account: account.name(), notes: folder.notes.length, default: folder.id() === defaultFolder,
    }))) };
    """#), target: target), from: target)
}

private let search = Operation(
  name: "search", summary: "Find notes whose title or text contains a phrase, newest first; without a query, the newest notes",
  effect: .reads,
  arguments: [
    Argument(name: "query", kind: .string, required: false, description: "Phrase to find, ignoring case"),
    Argument(name: "folder", kind: .string, required: false, description: "Folder id or exact name to search in; default all"),
    limitArgument,
  ]
) { arguments in
  try dictionary(runScript(script(#"""
    const scope = args.folder ? folderNamed(args.folder) : Notes;
    const sets = args.query ? [scope.notes.whose({ name: { _contains: args.query } }), scope.notes.whose({ plaintext: { _contains: args.query } })] : [scope.notes];
    const found = new Map();
    for (const set of sets) {
      const ids = set.id();
      const dates = set.modificationDate();
      ids.forEach((id, index) => found.set(id, dates[index]));
    }
    const newest = [...found.entries()].sort((a, b) => b[1] - a[1]).slice(0, args.limit);
    return { total: found.size, notes: newest.map(([id]) => {
      const note = Notes.notes.byId(id);
      const result = summary(note);
      if (!note.passwordProtected()) result.snippet = note.plaintext().slice(0, 200);
      return result;
    }) };
    """#), arguments: arguments.merging(["limit": limit(arguments)]) { $1 }, target: target), from: target)
}

private let read = Operation(
  name: "read", summary: "Read a note as plain text, and as HTML when asked", effect: .reads,
  arguments: [
    Argument(name: "id", kind: .string, required: true, description: "Note id from search"),
    Argument(name: "html", kind: .boolean, required: false, description: "Also return the body as HTML, with its formatting; default false"),
  ]
) { arguments in
  try dictionary(runScript(script(#"""
    const note = noteWithId(args.id);
    const result = summary(note);
    result.created = note.creationDate();
    result.text = note.plaintext();
    if (args.html) {
      const html = note.body();
      result.html = html.slice(0, 100000);
      if (html.length > 100000) result.html_truncated = true;
    }
    return result;
    """#), arguments: arguments, target: target), from: target)
}

private let create = Operation(
  name: "create", summary: "Create a note with a title and plain text", effect: .changes,
  arguments: [
    Argument(name: "title", kind: .string, required: true, description: "The note's title, its first line"),
    Argument(name: "text", kind: .string, required: false, description: "Plain text; line breaks become paragraphs"),
    Argument(name: "folder", kind: .string, required: false, description: "Folder id or exact name; default the default folder"),
  ]
) { arguments in
  try dictionary(runScript(script(#"""
    const folder = args.folder ? folderNamed(args.folder) : Notes.defaultAccount().defaultFolder();
    const html = '<div><h1>' + escape(args.title) + '</h1></div>' + (args.text ? paragraphs(args.text) : '');
    const made = Notes.make({ new: 'note', at: folder, withProperties: { body: html } });
    // The note exists from here on, so a failure to read it back must not look like nothing happened.
    try {
      const note = Notes.notes.byId(made.id());
      const text = note.plaintext();
      const result = summary(note);
      result.verified = plain(text) === plain(args.title + (args.text ? '\n' + args.text : ''));
      return result;
    } catch (error) {
      fail('outcome_unknown', 'Notes made the note but it cannot be read back (' + error.message + '). Search for it before trying again.');
    }
    """#), arguments: arguments, target: target), from: target)
}

let notesKnowledge = AppKnowledge(
  bundleId: "com.apple.Notes", name: "Notes", scripted: true, summary: "Find, read and create notes",
  access: "Read and change your notes, even while Notes is closed",
  hints: [
    "The sidebar lists folders by account; the note list and the editor are to its right. A note's first line is its title.",
  ],
  pitfalls: [
    "Runs of spaces and tabs in text become one space, because the body is HTML.",
    "Locked notes cannot be read or changed by any route until the user unlocks them.",
    "There is no operation that adds to an existing note: Notes gives its body back without attachments, checklist state or some formatting, so rewriting it loses them. Add to a note through the window, or create a new one.",
    "Notes starts if it is not running, to answer an operation; the app you were in gets the focus back if Notes takes it.",
  ],
  operations: [listFolders, search, read, create])
