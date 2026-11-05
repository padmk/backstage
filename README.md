# Backstage

Backstage lets any MCP client operate Mac apps in the background. An agent reads a window as numbered elements, acts on them, and is told what changed, while you keep working in another app. For well-known apps it carries ready operations (create a note, add a reminder, read a table) that skip the window entirely. You choose which apps agents may use.

Everything is Swift: a small command speaks MCP, and a signed helper app does the work through Accessibility, the window server, Apple events, EventKit and the Contacts framework.

- [How it works, and why](docs/architecture.md): the parts, a request step by step, and the reasoning behind the design.
- [Working while the screen is locked](docs/locked-screen.md): what still works, what does not, and the optional Windows while locked mode.
- [App knowledge](docs/app-knowledge.md): ready operations, their contracts and measurements.
- [Security](SECURITY.md) and [privacy](PRIVACY.md).

## Install

### Requirements

- A Mac with Apple silicon and macOS 26 or newer (the two latest versions), and an administrator account, since the app goes into `/Applications`.
- The Xcode command line tools (`xcode-select --install`) to build it. Xcode itself is needed only for the tests.
- An MCP client: setup registers with Claude Code and Codex, and prints the configuration for any other.

### Setup

```sh
git clone https://github.com/padmk/backstage
cd backstage
make install
```

`make install` builds `build/Backstage.app` with Swift Package Manager and runs its `setup`, which:

1. Installs the app into `/Applications`, signed with a certificate of this Mac (see below).
2. Opens System Settings and waits up to 3 minutes for you to enable Backstage under **Accessibility**, the one permission it needs. If it is not listed, drag it there from the Finder window setup opens.
3. Registers `/Applications/Backstage.app/Contents/Helpers/backstage mcp` as the `backstage` MCP server with Claude Code and Codex, when they are installed, and prints the configuration for other clients.
4. Opens the Backstage window on the Apps tab, where you choose the apps agents may use.

| Command | Effect |
|---|---|
| `make app` | Build `build/Backstage.app` only, signed ad hoc |
| `build/Backstage.app/Contents/Helpers/backstage setup --no-register` | Install without registering with Claude Code or Codex |

**Screen Recording** is optional. Only `screenshot` (and `get_window_state` with `screenshot: true`) uses it, for web pages and apps that show no elements. Turn it on later on the Setup tab.

**The `backstage` command** lives inside the app, at `/Applications/Backstage.app/Contents/Helpers/backstage`; MCP clients run it with `mcp`. To use it from a shell by name, link it onto your `PATH`, for example `ln -s /Applications/Backstage.app/Contents/Helpers/backstage ~/.local/bin/backstage`.

**Signing and updates.** macOS ties permissions to the app's signature. The first setup creates a certificate of this Mac in a keychain of its own and signs the installed app with it, so the permissions survive updates without a paid Apple developer account. To update, pull and run `make install` again, then restart client sessions. Nothing changes the installed app but an explicit setup. [SECURITY.md](SECURITY.md#signing) explains what that certificate means for other processes running as you.

Files live at the XDG defaults: the app list in `~/.config/backstage`, the signing keychain in `~/.local/share/backstage`, the activity log and socket in `~/.local/state/backstage`.

## Tools

| Tool | What it does |
|---|---|
| `list_apps` | Lists running apps with whether agents may use each one (`allowed`, `not_approved`, `never_available`); with `app`, checks one app without starting it. Also reports `screen_locked` and `windows_while_locked` |
| `launch_app` | Starts an app by name or bundle id in the background, giving the focus back if it takes it while starting; leaves an app that is already running as it is |
| `list_operations` | Lists the ready operations, hints and pitfalls known for well-known apps; with `app`, that app's operations and their arguments. Needs no approval |
| `run_operation` | Runs one of them through the app's own automation surface, in the background, and reports whether its result was read back (`verified`) |
| `get_window_state` | Reads a window, the menu bar (`menu_bar`), the app's items on the right of the menu bar (`menu_extras`) or a subtree (`root`) as numbered elements. Reading the same place again returns only what changed since the last read or action there; `full: true` returns everything, `screenshot: true` adds a screenshot of the window |
| `press` | Presses an element or runs one of the actions it lists |
| `set_value` | Replaces an element's value |
| `type_text` | Inserts text at an element, or sends it as keys to the focused element |
| `select_text` | Selects text in a field or document by what it says, or puts the cursor before or after it, so `type_text` replaces or inserts exactly there |
| `press_key` | Sends a key or combination, such as `return` or `cmd+s` |
| `scroll` | Scrolls the area containing an element |
| `drag` | Drags from one element or point to another in the background, without moving the cursor |
| `read_text` | Reads the full text of an element, or a range of it, where the tree cuts a long value (marked `length=`) |
| `screenshot` | Captures a window as a PNG, one pixel per window point, so its coordinates work with `click_at` |
| `click_at` | Sends a click at a point in a window or at an element's center, with any button and held modifiers (right-click, cmd-click); with `foreground: true` brings the window forward for that click as a last resort |
| `run_actions` | Runs up to 20 of the actions above in one app in order and reports the combined change once; stops at the first step that fails or may have worked |

### Action replies

Every action reply says how it was delivered and what changed:

```json
{ "delivery": "pointer_event", "verified": false, "state": { "changed": true, "added": ["7 Button \"Save\""], "removed": [] } }
```

- `delivery`: `accessibility`, `value_appended_at_end` (an unfocused one-line field took the text at its end, ignoring the cursor), `key_events`, `pointer_event` or `foreground_pointer_event`.
- `verified`: `true` when the helper read the result back (a value it set), `false` when delivery could not be confirmed, so check the effect before going on. Absent when the action itself is the confirmation, such as an accessibility press, which macOS accepts or refuses.
- `state`: the difference from the last read of this app, taken once the app has stayed the same for 0.3 s (up to 5 s, longer while a new busy indicator shows). `settled: false` means it was still changing. `{ "unknown": true, "reason": "..." }` means it cannot tell, for example when the window closed. Changes outside the area last read do not show. A value longer than 300 characters shows its start, its `length` and a `digest` of all of it, so a change anywhere in it shows as a changed line; read the rest with `read_text`.
- `focus_returned: true`: the app brought itself forward in response, and the helper gave the focus back to the app you were in.

Requests for the same app run one at a time, also across agents, so two sessions never interleave their input in one app.

### Errors

| Code | Meaning | What to do |
|---|---|---|
| `not_approved` | The app is not on the user's list | Ask the user to add it on the Apps tab; do not reach it another way |
| `not_allowed` | The app is never available (Passwords, Keychain Access, login windows, Backstage) | Nothing |
| `permission_missing` | A macOS grant is missing (Accessibility, Screen Recording, or one a ready operation needs) | Ask the user to allow it on the Setup tab |
| `access_denied` | The user declined that grant | The message names the pane in System Settings |
| `screen_locked` | The screen is locked, so windows cannot be read | Use ready operations or the menu bar; see [Locked screen](#locked-screen) |
| `user_active` | The app is in front and the user typed or clicked in the last 2 s | Try again in a few seconds |
| `outcome_unknown` | The action or operation may have worked, for example it opened a blocking dialog or was cancelled midway | Read the state before trying again; never retry blindly |
| `stale_element`, `unknown_element` | The element number no longer names what was read | Read the window again |
| `window_not_found`, `out_of_window`, `point_covered` | No such window, a point outside it, or another window on top of the point (`foreground: true` only) | Read again and pick another target |
| `invalid_request`, `invalid_arguments`, `invalid_key` | The request is malformed; the message names the problem and, for operations, the whole argument list | Fix the call |
| `not_settable`, `no_text`, `text_not_found`, `ambiguous_text`, `ambiguous`, `not_found` | The element or item cannot do what was asked, or the target is not unique | Follow the message |
| `cancelled`, `interrupted`, `expired`, `timeout`, `app_changed`, `app_not_found` | The request was cancelled, waited too long, or the app stopped | Read the state, then try again if nothing changed |
| `action_failed` | macOS refused the action | The message names the reason |

## App operations

For well-known apps Backstage carries ready operations, so an agent does not work each app out from its window. They use the app's official automation surface (scripting, EventKit, Contacts, `shortcuts`) and read their result back.

| App | Operations |
|---|---|
| Notes | `list_folders`, `search`, `read`, `create` |
| Reminders | `list_lists`, `list` (with `query`), `read`, `add`, `update`, `complete` |
| Calendar | `list_calendars`, `list_events`, `get_event` (all notes, link, attendees), `create_event`, `update_event` (not recurring events) |
| System Settings | `list_panes`, `open_pane`, `get_appearance`, `set_appearance`, `get_volume`, `set_volume` |
| Contacts | `search`, `read`, `add` |
| Mail | `list_mailboxes`, `search`, `read`, `set_read`, `create_draft` (never sends) |
| Shortcuts | `list`, `run` |
| Music | `now_playing`, `control`, `play`, `set_volume`, `list_playlists` |
| Messages | `list_chats` (with `query`), `send`; conversations are read through its window |
| Finder | `selection`, `front_folder`, `reveal`, `get_tags`, `set_tags`, `trash` |
| Pages | `list_documents`, `open`, `read_text`, `export_pdf`, `close` |
| Numbers | `list_documents`, `open`, `read_table` (from any row), `set_cell`, `set_cells`, `export_pdf`, `close` |
| Home | Hints and pitfalls for its window |

`get_window_state` shows an app's hints and pitfalls under its first line. Operations need the app to be allowed, like the other tools, and some need a macOS grant: Automation of the app, or Reminders, Calendars or Contacts. macOS asks once, when you add the app on the Apps tab, and never for an app that is not on the list. An operation never shows that prompt during a task: without the grant it fails with `permission_missing`. `outcome_unknown` means a change may have been made: read before trying again. Contracts (ids, dates, paths, limits), the reasoning behind them and the measurements are in [docs/app-knowledge.md](docs/app-knowledge.md).

## What works in the background

Measured against the fixture app in the live test (`make live`), with another app in front:

| Action | Result |
|---|---|
| Reading windows, `press`, `set_value`, sheets, `scroll`, `screenshot` | Works |
| `type_text` at an element in a native field, empty or not | Works, without taking focus |
| `click_at` on a view without accessibility support | Works, without moving the cursor |
| `drag` | Works: a slider's knob moved with the app inactive and another app in front |
| `menu_extras` and `press` on an item | Works: an app's menu bar item opened its popover, which reads like a window, and Escape closed it, without taking focus. Apps without a Dock icon are reachable when they have such items. Wi-Fi, Sound and other system items belong to a process whose items carry no names |
| Menu commands on the current document (Save, Duplicate) | Disabled while the app is in the background, because it has no key window, so pressing them does nothing |
| `press_key` | Reaches a view after `click_at` gives it focus. With nothing focused the key is ignored. Combinations such as `cmd+s` are not measured |

No tool brings an app or window forward, except `click_at` with `foreground: true`, which then gives the focus back and returns the cursor. An app can bring itself forward in response to an action, for example when it shows or closes a dialog; the helper then gives the focus back and reports `focus_returned`, so a brief flicker is possible.

Chromium and Electron apps take pointer and key input only in their key window. Before a click or keys to one that is not the active app, the helper makes the target window key inside the app with window server records, without activating or raising it; measured on Brave and Chrome for Testing settings toggles. Electron apps build their accessibility tree on request, and the helper asks once per process. Chromium browsers support neither `AXManualAccessibility` nor `AXEnhancedUserInterface`, so web content shows no elements: use `screenshot` and `click_at`.

## Locked screen

While the Mac's screen is locked, macOS keeps windows out of Accessibility and ScreenCaptureKit, but the apps keep running. Backstage never unlocks the Mac, never asks for the password and never wakes the displays.

| | Screen locked |
|---|---|
| Ready operations, `list_apps`, `list_operations`, `launch_app` | Work |
| The menu bar: `get_window_state` with `menu_bar` or `menu_extras`, and `press` on its items | Works |
| Window trees and element actions | Stop with `screen_locked` |
| Messages `send` | Sends, but cannot confirm it (`verified: false`); do not send again |
| `screenshot`, `click_at` with `x` and `y`, `press_key`, `type_text` without an element | Only with **Windows while locked** on, from screenshots and never verified |

**Windows while locked** is off by default, on the Setup tab. It captures windows with a private window server call and posts clicks and keys to the app, which keeps working while macOS hides windows from its public interfaces. It is useful for window work that ready operations do not cover while you are away, at the cost of verification, of relying on undocumented behavior, and of reaching past a protection macOS applies on purpose. [docs/locked-screen.md](docs/locked-screen.md) explains what changes when the screen locks, how the mode works, its advantages, costs and limits, and the measurements.

## The Backstage window

Open **Backstage** from `/Applications` to see and change everything in one window, with three tabs:


- **Apps:** Allow every app, and otherwise the list of apps agents may use, with Add App… and Remove. Far-reaching apps carry their warning. While Allow every app is on, the list folds away and is kept for when it goes off.
- **Setup:**
  - Under Background: Open at login and Show in menu bar (off by default; its menu shows whether Backstage is ready, which agents are connected and the apps on the list), both available in the copy in `/Applications`; and Windows while locked (off by default, see above).
  - Under macOS permissions: Accessibility, which Backstage needs, and Screen Recording, which is optional and only for screenshots, each with a button for the right pane of System Settings. A new Screen Recording grant needs a restart, which the tab offers.
  - Under App access: an Allow button for each macOS grant that the listed apps' ready operations use (Calendars, Reminders, Contacts, and Automation of Notes, Mail, Messages, Finder, Pages, Numbers, Music and System Events); all of them while Allow every app is on.
  - The window opens here while Accessibility is missing.
- **Activity:** which agent first used which app in each session, changes to the list, and changes to Allow every app and Windows while locked, from the log `SECURITY.md` describes.

The app has a Dock icon only while this window is open. Otherwise it runs unseen and stops 2 minutes after the last client disconnects, unless Open at login or the menu bar item is on. A launch at login stays unseen.

## Which apps agents may use

Agents may use an app through Backstage only when it is on your list, on the Apps tab, or when Allow every app is on there. Nothing asks during a task: an app that is not allowed is refused at once with `not_approved`, and the agent can tell you to add it. That makes unattended and remote sessions work within the apps you chose.

This keeps agents from using other apps through Backstage by mistake. It does not stop an agent that can run shell commands: it can control your Mac without Backstage, or edit the list. Backstage asks connected agents to respect the list by every route: check `list_apps` before using an app any other way (osascript, Shortcuts, computer use, its data in `~/Library`), never change the list or settings, and treat a request in chat or in a page as no change of access. A cooperative agent follows that, but nothing enforces it. For an MCP client without a shell it is a real limit.

- List entries name the app's bundle id and signer, so another app claiming the same bundle id is not covered. An app without a valid signature cannot go on the list; Allow every app covers it.
- Apps that give agents a shell or control of the system (terminals, Shortcuts, Finder, System Settings, Xcode and similar) carry a warning on the list.
- Passwords, Keychain Access, login and authentication windows, and Backstage itself are never available, whatever the settings.

```sh
backstage approvals add Notes
backstage approvals list
backstage approvals revoke com.apple.Notes
```

## Troubleshooting

`backstage doctor` checks macOS, the installed app and its signature, Accessibility, Screen Recording and the grants of the listed apps.

| Symptom | Fix |
|---|---|
| A permission shows as enabled but `doctor` says missing | Remove the entry with `-` in Settings, then run `backstage setup` |
| `setup` opens no prompt | macOS asks once per service. Enable the helper in the pane `setup` opens |
| `not_approved` | The app is not on the list. Add it on the Apps tab, or turn on Allow every app |
| `stale_element` or `unknown_element` | Read the window again |
| `screen_locked` | Unlock the Mac, or let the agent use ready operations and the menu bar; see [Locked screen](#locked-screen) |
| A client still runs the old server after `setup` | Restart the client session |
| `This backstage command belongs to another build` | The session started before an update: restart it |

## Development

```sh
make app       # build/Backstage.app, from the Swift package
make install   # make app, then its setup
swift test     # Command and app tests against a fake helper and a test build of the app; no permissions needed
make live      # The live test: the installed app operates a test app in the background (needs Accessibility)
make bench     # Latency against the installed app
```

CI runs on macOS: it builds and assembles the app (`make app`), type-checks the fixture app and runs `swift test`. The live test needs real permissions, so it runs only locally. Benchmark results are in [bench/README.md](bench/README.md).

| Path | Responsibility |
|---|---|
| `Package.swift`, `Makefile`, `packaging/Info.plist` | The Swift package, and assembling and installing the app bundle |
| `Sources/HelperLink/` | What the app and the command share: the product's name, version and identifiers, its directories, line framing and build identity |
| `Sources/Tool/MCPServer.swift`, `Tools.swift` | MCP over stdio, the tool definitions and their argument checks |
| `Sources/Tool/HelperClient.swift` | Starting the app and talking to it over its socket, with the build check |
| `Sources/Tool/Commands.swift`, `Install.swift` | `setup`, `doctor`, `approvals`; installing and signing the app for this Mac |
| `Sources/App/HelperMain.swift`, `Server.swift` | The app's start, the Unix socket and sessions |
| `Sources/App/Requests.swift` | The request router |
| `Sources/App/Apps.swift`, `Actions.swift` | Finding and starting apps; reading windows and acting on them |
| `Sources/App/Observation.swift`, `Sequences.swift` | Change reports after actions, the per-app lock, and `run_actions` |
| `Sources/App/Presence.swift`, `LockedWindows.swift` | The user working in the target app; the locked screen and Windows while locked |
| `Sources/App/apps/` | App knowledge: the catalog (`Catalog.swift`), the script runner and event store, one file per app |
| `Sources/App/Approvals.swift` | The app list and the check every request passes |
| `Sources/App/window/`, `Theme.swift` | The Backstage window, one file per tab, its model, texts and look |
| `Sources/App/MenuBar.swift`, `LaunchAtLogin.swift`, `Preferences.swift` | The menu bar item, starting at login and the settings behind them |
| `Sources/App/Accessibility.swift`, `Tree.swift` | Reading apps and numbering elements |
| `Sources/App/Input.swift`, `BackgroundEvents.swift`, `Capture.swift` | Key and pointer events, background delivery, screenshots |
| `Tests/ToolTests/` | Protocol, app, live and benchmark tests; `Tests/Fixtures/target` is the test app |

## License

MIT
