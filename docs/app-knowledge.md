# App knowledge: operations, hints and pitfalls

Working through a window means reading it and working out where things are, in every task and every app. This layer gives each well-known app a definition the agent can use at once, so it does not rediscover the app each time.

## Order of routes

For each app, the definition uses the first route that works:

1. **The app's own automation surface**: its AppleScript dictionary, a system framework that owns the data (EventKit for reminders and calendars, Contacts for contacts), `x-apple.systempreferences:` URLs and preference domains for System Settings, Shortcuts for apps that offer them.
2. **Accessibility with per-app knowledge**: hints about where things are, which custom actions to use, what not to do.
3. **Screenshots and `click_at`**, for views without elements.

Route 1 is fast, needs no window, works when the app is hidden or not running and while the screen is locked (see [locked-screen.md](locked-screen.md)), and can be read back exactly. Route 2 and 3 stay the fallback for everything an app does not script.

## What an app definition holds

One Swift file per app in `Sources/App/apps/`, keyed by bundle id:

- **Operations**: named, typed actions such as `notes.create` or `reminders.add`. Each declares its arguments (name, type, required, description), whether it changes anything (`reads` or `changes`), and a function that runs it and returns a result with `verified`.
- **Hints**: a few short lines for an agent working through accessibility: where things are in the window, which custom actions an element offers, which keys work.
- **Pitfalls**: known traps, such as Home's favorite colors also changing brightness.

The catalog is plain data in the helper, which is also where operations run, so there is one owner for each rule.

## How it is exposed through MCP

Two tools, not one tool per operation:

| Tool | What it does |
|---|---|
| `list_operations` | Without `app`: the apps that have a definition, with a one-line summary each. With `app`: that app's operations with their argument schemas, its hints and pitfalls. Needs no approval: it is static knowledge and touches no app |
| `run_operation` | Runs one operation: `app`, `operation`, `arguments`. Passes the same approval gate as every other tool |

`get_window_state` adds the app's hints and pitfalls under its header line, with a pointer to `list_operations` when the app has operations, so an agent that starts with a read learns about the faster route.

**Why not one tool per operation.** The first batch alone has about 20 operations. Every tool's schema is sent to the model in every conversation, whether the task touches Notes or not, which costs context and makes choosing harder. Two tools keep the list short (16 tools in all), and the agent loads one app's schemas only when it needs them. The cost is a discovery step, which `get_window_state` hints and the server instructions point to, and arguments that MCP clients cannot check against a schema, so the helper validates them and names the problem.

## Approval and macOS permissions

- `run_operation` resolves the app by bundle id (running or only installed, as `launch_app` does), looks the operation up in that app's own catalog only, validates the arguments in the helper (so a request sent straight to the socket meets the same checks) and calls `ApprovalGate.require` with the app. `app=Notes` with a Calendar operation is unknown, not a way into Calendar. Scripts, preference domains and targets are fixed in the catalog; only data travels as arguments.
- Allowing an app covers both its window and its operations. For apps whose data a framework reaches directly (EventKit for Reminders and Calendar), that means reading and changing the data in every account, even while the app is closed and with no process involved, and the app list says so under those apps. A macOS grant never replaces the app list: both are needed. Far-reaching apps (System Settings, Finder, Shortcuts) carry a warning on the list.
- Operations run inside the helper, so macOS attributes every permission to Backstage:
  - Scripts are JavaScript for Automation, run by an `osascript` child of the helper. A child inherits the helper as its responsible process, so the Automation prompt should name Backstage; this is checked live, not assumed. The arguments go in as one JSON value after `--` to `run(argv)`, never spliced into the script text, so no input can change what a script does. Each run has a timeout, after which it is killed.
  - EventKit runs in the helper itself and asks with `requestFullAccessToReminders` and `requestFullAccessToEvents`, treating only `.fullAccess` as granted. `Info.plist` carries `NSAppleEventsUsageDescription`, `NSRemindersFullAccessUsageDescription` and `NSCalendarsFullAccessUsageDescription`, and the build fingerprint covers the plist, so a changed usage string rebuilds the app.
- Contacts uses the Contacts framework in the helper and needs `NSContactsUsageDescription`; Shortcuts runs `/usr/bin/shortcuts` as a child of the helper, always naming the shortcut by its id.
- WhatsApp has no automation surface, so its operations read its own SQLite database (`ChatStorage.sqlite` in its group container) read-only, with the write-ahead log, while WhatsApp runs or not. macOS guards that container as another app's data and, for Backstage, refuses without a prompt; Full Disk Access is the only grant that opens it, and macOS never asks for that one. So the Setup tab's WhatsApp row opens the pane with a panel to drag Backstage from, and the helper reads the files only after the user has asked there, since reading is what would make macOS ask on versions that do. The format is WhatsApp's own: the operations check the tables and columns they need and fail with `unsupported_format` otherwise, leaving the window as the way in. Times are Core Data seconds since 2001; message types 0 to 15 are named where known (14 is a deleted message); a document's text is its file name and an attachment's caption sits on the attachment. `save_media` copies an attachment to a temporary folder, because the agent's own process cannot read WhatsApp's folder, and refuses a stored path that leads outside it.
- Messages reads conversations the same way, from `~/Library/Messages/chat.db` with the write-ahead log, behind its own grant (Messages history) next to its Automation grant; `list_chats` uses the database while that grant is on and scripting otherwise, so either grant serves it; reading from the database (`list_chats` with that grant, `read_chat`, `save_attachment`) never starts Messages. Chat ids are the database's `guid` (`any;-;+48…` on current macOS); a phone number, email address or group name also finds a chat when only one matches. Message text is in `text` or, on current macOS, only in `attributedBody`, an NSArchiver typedstream: a small bounded reader takes its first NSString, since an unarchiver in the helper would decode bytes that strangers sent; a body it cannot read comes back as `text_unreadable`. Dates are nanoseconds since 2001 (seconds on old databases), paging uses date then id, reactions (`associated_message_type`) are left out and other item types show as `event`. `save_attachment` copies into a new private folder per copy and refuses paths outside `~/Library/Messages/Attachments` and anything but a regular file.
- macOS shows each of these prompts once per data type or target app. macOS asks for an app's grants when the user adds it on the Apps tab, while they are at the keyboard, and never for an app that is not on the list. The Setup tab lists the grants of the listed apps under App access, with an Allow button each (every grant while Allow every app is on). Allow asks macOS; once macOS has an answer only System Settings can change it, so a declined grant offers Open Settings instead. macOS reports Automation only for a running app, so such a row says so until the app runs. An operation never shows the prompt itself, so a task cannot stall on a dialog no one answers: before it runs, a grant macOS has not asked about fails it with `permission_missing` (Automation is checked once the app runs, since macOS cannot tell before), and a declined one with `access_denied` naming the pane in System Settings.
- A TCC prompt is a system dialog that comes to the front. That happens once per grant, not per use, and only after the user added the app.

## Background first

EventKit touches no app at all. Apple events can launch a target that is not running, without activating it, and a target may still react by showing a window; the helper records the front app before each operation and gives it the focus back if the target took it, reporting `focus_returned`. An app that operations script (Notes, Mail, Messages, Music, Finder, Pages, Numbers) and that is not running is started by the helper hidden, without activation and without reopening the windows it had when it last quit (`-ApplePersistenceIgnoreState YES`), before the first Apple event reaches it; if it shows itself while answering, the helper hides it again, since nothing of the user's is in it. Without this, a started app's windows appear above the user's other apps even when the focus stays put. An app the user already runs is left as it is. Giving the focus back does not undo a change in z-order, so an operation that would bring a window forward on its own ships only once it is measured to stay behind. `open_pane` is: opened with `activates = false`, System Settings starts or switches pane behind the front app, which keeps the focus (measured on macOS 27.2 with System Settings closed and open).

## How each operation proves it worked

Every operation that changes something reads its result back through the same route and returns `verified: true` only when the read matches what was asked. `verified` means the postcondition was observed on this Mac, not that iCloud has synced it.

A script that times out, a change cancelled while it runs (its script child is stopped) or a failed read-back after a change returns `outcome_unknown`; a request cancelled before it acts returns `cancelled` and changes nothing: an Apple event already delivered cannot be called back, so the item may exist. Nothing retries a change or falls back to another route by itself, which would create duplicates; the agent reads the state first.

| Operation kind | Read-back |
|---|---|
| Create (note, reminder, event) | Fetch the new item by the id the app returned and compare title, body or dates |
| Update (complete, set a cell) | Fetch the item again and compare the changed field |
| Send a message | Messages' scripting cannot read messages, so the helper reads the chat list in its window through accessibility: a new chat label holding the text confirms it. While the screen is locked the list cannot be read, so the reply is `verified: false` and says so |
| Move to the Trash | The item is gone from its path; Finder returns where it went |
| Open a pane | System Settings' window title, read through accessibility, changes or matches the pane's name. A title alone cannot prove which subsection is shown |
| Setting (appearance, volume) | Read the live setting from its owner after setting it: System Events' appearance preferences, the audio volume from Standard Additions; not a preference file |

The result carries the item's id, so the agent can refer to it later without searching.

## Scope

Backstage covers a fixed set of macOS's own apps; apps from other makers are out of scope, because they change often and have their own CLIs and MCP servers. Within that set each app gets a small number of operations that agents ask for often, and generic gaps in the driver (drag, menu bar extras, system dialogs) keep their place, because they help every app.

| Order | Apps |
|---|---|
| Done | Notes, Reminders, Calendar, System Settings |
| Done | Mail (without sending), Contacts, Shortcuts, Music |
| Done | Messages (sending; reading from its database with Full Disk Access, or through its window), Finder (selection, reveal, tags, Trash) |
| Done | Pages and Numbers |
| Done | WhatsApp (reading, from its database) |
| When it can be measured | Keynote: not installed on the Mac these were built on, and operations ship only once measured |
| Hints only | Home: HomeKit needs an entitlement a locally signed app cannot have, so scenes go through Shortcuts |

### Operations

| App | Operations |
|---|---|
| Notes | `list_folders`, `search`, `read`, `create` |
| Reminders | `list_lists`, `list` (with `query`), `read`, `add`, `update`, `complete` |
| Calendar | `list_calendars`, `list_events`, `get_event`, `create_event`, `update_event` (not recurring events) |
| System Settings | `list_panes`, `open_pane`, `get_appearance`, `set_appearance`, `get_volume`, `set_volume` |
| Contacts | `search`, `read`, `add` |
| Mail | `list_mailboxes`, `search`, `read`, `set_read`, `create_draft` |
| Shortcuts | `list`, `run` |
| Music | `now_playing`, `control`, `play`, `set_volume`, `list_playlists` |
| Messages | `list_chats` (with `query`), `read_chat`, `save_attachment`, `send` |
| WhatsApp | `list_chats` (with `query`), `read_chat`, `save_media` |
| Finder | `selection`, `front_folder`, `reveal`, `get_tags`, `set_tags`, `trash` |
| Pages | `list_documents`, `open`, `export_pdf`, `close`, `read_text` |
| Numbers | `list_documents`, `open`, `export_pdf`, `close`, `read_table`, `set_cell`, `set_cells` |

Contracts:

- Items are named by the ids their owner gives (note ids, EventKit calendar and item identifiers). Destinations are ids from the list operations, or names that match exactly one; read-only lists and calendars are refused.
- Times are ISO 8601. A time without an offset is local time. All-day events take dates (`2026-11-05`), and their `end` is the last day, inclusive. Results give times with the local offset.
- Searches and lists are bounded by `limit` (default 20, at most 200), and event ranges by at most 366 days.
- Paths for files are absolute or start with `~`, and must be in the home folder (not the folder itself) or on an external volume; one module owns this rule. In the home folder's Library only iCloud Drive (`Mobile Documents`) and `CloudStorage` are reachable: Library holds other apps' data, which Full Disk Access, granted for WhatsApp, would otherwise open to every operation that takes a path. `export_pdf` never replaces an existing file.
- Pages and Numbers answer as their Creator Studio versions (`com.apple.Pages`, `com.apple.Numbers`, 15.4) or the earlier ones (`com.apple.iWork.Pages`, `com.apple.iWork.Numbers`, 14.5), which have the same scripting: a running one is used, otherwise the first installed in that order. Each needs its own approval and Automation grant.
- Apple announced on 27 October 2026 that Keynote, Pages and Numbers gain MCP support on macOS 27, letting external agents read, edit and run actions in documents, in an update due in November. It is not measured yet: whether it needs the Creator Studio subscription and how agents connect are not stated. Once it ships, compare it with these operations and, if it is better, point agents to it with a hint instead of growing the operations.
- iWork documents are named by id or name; scripts hold them by id, because Numbers renames a new document from its content.
- Panes are the Settings extensions installed in `/System/Library/ExtensionKit/Extensions`, so `open_pane` accepts only ids this Mac has and the list follows the macOS version.
- Notes bodies are HTML inside Notes. `create` takes a title and plain text and builds escaped HTML with the title as heading. Nothing adds to an existing note: Notes gives the body back without attachments, checklist state and some formatting (an image vanished in a test), so any rewrite can lose content. `read` returns plain text, and HTML too with `html: true`. Locked notes are refused.

Deleting, replacing a note's whole body and changing recurring events wait until there is a clear story for destructive operations. Undoing a create through a session-bound record of what this helper made, and recurring events (one occurrence or the series), are designed then.

## Not in scope now

- Per-operation approvals or a separate gate for destructive operations: approval stays per app.
- A plug-in format for definitions outside the helper: they are compiled in, and signed with it.
- Generic AppleScript execution: an agent with a shell already has `osascript`, and an open script tool behind the gate would turn one approval into control of every scriptable app.

## Measured on this Mac

macOS 27.2, 4 November 2026, with another app in front throughout. Each operation is listed with its typical time once approved.

| App | Result |
|---|---|
| Notes | All four operations work, about 0.5 s each; the Automation prompt named Backstage. Markup in titles and text arrives escaped |
| Reminders | All work, about 0.3 s; `update` changes only the fields given and moves the due-time alert while keeping relative and location alerts. Dates and local times round-trip with the local offset; read-only lists are refused |
| Calendar | All work, about 0.3 s; `update_event` keeps an event's length when only start moves and refuses recurring events and their changed occurrences, for timed and all-day events; the read-only Birthdays calendar is refused |
| System Settings | All six work, 0.4 to 1.6 s. The front app kept the focus while `open_pane` started System Settings and switched panes. Setting a volume level unmutes the output |
| Contacts | All three work, about 30 ms. Search matches the start of names and whole email addresses or phone numbers |
| Mail | `list_mailboxes`, `search` and `create_draft` work; no Mail account was enabled, so `read` and `set_read` are not measured. A draft is found as the new id in Drafts and its recipients and body are read back; with no enabled account that check is not measured |
| Shortcuts | `list` works; the command lists every shortcut for an unknown folder, so the folder is checked first. `run` is measured only for an unknown shortcut, because every installed one acts on something |
| Music | All five work, 0.1 to 1.8 s; Music started behind the front app, which kept the focus |
| Messages | `list_chats` and `send` work; a test message was confirmed through the chat list in about 0.3 s. Messages labels each chat with its latest message. From the database: `list_chats` answered every chat, and `read_chat` read a few thousand messages in 0.9 s (at most 0.1 s for 500), text for all but 4 (attachments alone), accented letters and emoji intact; paging by 13 with `before` matched one read of 300. Most attachments of a Messages in iCloud account were not on the Mac, which `save_attachment` reports as `not_found` |
| WhatsApp | Measured with WhatsApp 26.44.15: `list_chats` about 7 ms, `read_chat` 14 ms for 50 messages and 100 ms for 500, `save_media` 2 ms. A day's messages matched what the window showed, including messages still in the database's write-ahead log, photos with captions, links, a document and group senders |
| Finder | All six work. Finder asks for an administrator password to trash a symbolic link and then fails, so links go to the Trash directly; other items go through Finder for Put Back. Paths outside the home folder and external volumes, and the home folder itself, are refused |
| Pages | All five work, 0.2 to 1.8 s. A plain text file opens as a new document without a file (`imported: true`) |
| Numbers | Started hidden by an operation, Numbers Creator Studio showed no window and the front app kept the focus. All six work. Cells outside the table are refused; numbers and text are recognized as if typed. A new or imported document is named from its content (here "Fruit and Vegetable List") and saved to iCloud Drive as soon as it changes |
