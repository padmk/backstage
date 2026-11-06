# Privacy

Backstage sends nothing over the network itself. It has no telemetry.

## What leaves the Mac

Window contents, screenshots and the results of ready operations (notes, reminders, events, contacts, mail, chats, tables) of the apps you allow go to the MCP client that asked for them, and that client may send them to its model provider. Secure field values are never returned in a read, but other text and any screenshot can contain sensitive data. With Windows while locked on, screenshots can be taken while the screen is locked and you are not watching. Allow only the apps your tasks need.

## What stays on disk

| File | Holds |
|---|---|
| `~/.config/backstage/approvals.json` | The app list: bundle ids and signers (entries made by earlier versions may carry an expiry time) |
| `~/.local/state/backstage/decisions.jsonl` | Time, client, app and decision of each first use in a session and each change to the list, Allow every app or Windows while locked; past 200 KB it keeps the newest thousand records |
| `~/.local/share/backstage/signing.keychain-db` | The local signing certificate and its key |
| `~/Library/Preferences/app.foreverbeta.backstage.plist` | The window's switches and last tab |

None of them holds window contents or operation results. Ready operations that list files (Finder's selection and front folder, the documents Pages and Numbers have open) leave out the paths of files outside your home folder and external volumes. Delete `approvals.json` and `decisions.jsonl` to reset the list and the history.
