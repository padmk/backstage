# Privacy

Backstage sends nothing over the network itself. It has no telemetry. macOS may: Photos' `export` asks PhotoKit for an item that is only in iCloud and lets it download the item (the reply says `downloaded`), and the apps an agent operates use the network as they would for you, as when Messages sends a message.

## What leaves the Mac

Window contents, screenshots, recordings of what an app plays (`record_audio`) and the results of ready operations (notes, reminders, events, contacts, mail, chats, Messages and WhatsApp messages and attachments, photos and videos, tables) of the apps you allow go to the MCP client that asked for them, and that client may send them to its model provider. Secure field values are never returned in a read, but other text and any screenshot can contain sensitive data. Text recognized in a screenshot (`text: true`) is recognized on this Mac with Apple's Vision framework and, like the image, is neither stored nor sent anywhere except in the reply to the agent that asked. With Windows while locked on, screenshots can be taken while the screen is locked and you are not watching. Allow only the apps your tasks need. When Contacts is on your list and macOS allows Backstage to read it, Messages' `list_chats` and `read_chat` read contact names, only to label chats and senders by the names Messages shows; they never ask for Contacts access.

## What stays on disk

| File | Holds |
|---|---|
| `~/.config/backstage/approvals.json` | The app list: bundle ids and signers (entries made by earlier versions may carry an expiry time) |
| `~/.local/state/backstage/decisions.jsonl` | Time, client (the name the MCP client reports, as one line of at most 40 characters), app and decision of each first use in a session and each change to the list or the list of other Macs (by the name ssh reaches each under), Allow every app or Windows while locked; past 200 KB it keeps the newest records that fit in 100 KB, at most a thousand |
| `~/.local/share/backstage/signing.keychain-db` | The local signing certificate and its key |
| `~/.config/backstage/settings.json` | The window's switches and last tab, which apps' data macOS has been asked about, and the other Macs agents may reach |
| `whatsapp-media`, `messages-attachments`, `photos-export` and `audio-recordings` in the system's temporary folder | Copies an agent asked for with WhatsApp's `save_media`, Messages' `save_attachment` or Photos' `export`, and recordings made with `record_audio`, each in a private folder of its own; macOS clears them over time |
| `shortcut-<id>` in the system's temporary folder | While Shortcuts' `run` runs: the shortcut's input (`input.txt`) and output (`output.txt`), in a private folder removed when the shortcut ends |

To tell when you are working in an app, the helper watches your clicks, scrolling and dragging in every app as they happen and keeps, in memory only, which app's window took them and when, for two seconds; it does not watch typing, keeps no positions, and writes or sends none of it. Apart from those copies, recordings and a running shortcut's input and output, none of the files above holds window contents or operation results. Ready operations that list files (Finder's selection and front folder, the documents Pages and Numbers have open) leave out the paths of files that operations may not reach: outside your home folder and other volumes, in your Library apart from iCloud Drive and cloud storage, and in another home's Library or a Time Machine backup on another volume. The arguments of ready operations, such as a message's text or a search, reach their `osascript` children on standard input, so they show neither on disk nor in the list of processes. Delete `approvals.json` and `decisions.jsonl` to reset the list and the history.
