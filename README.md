<p align="center">
  <img src="assets/AppIcon.png" width="128" alt="">
</p>

<h1 align="center">Backstage</h1>

<p align="center">Let AI agents use your Mac's apps in the background, while you keep working.</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B%20%C2%B7%20Apple%20silicon-black" alt="macOS 26 or newer on Apple silicon">
  <img src="https://img.shields.io/badge/Swift-6.2-black" alt="Swift 6.2">
  <img src="https://img.shields.io/badge/MCP-stdio-0a7ea4" alt="MCP server over stdio">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-black" alt="MIT license"></a>
</p>

<p align="center">
  <a href="#install"><b>Install</b></a> ·
  <a href="#see-it-work"><b>See it work</b></a> ·
  <a href="#for-ai-agents"><b>For AI agents</b></a> ·
  <a href="#tools"><b>Tools</b></a> ·
  <a href="#documentation"><b>Docs</b></a> ·
  <a href="CHANGELOG.md"><b>Changelog</b></a>
</p>

<p align="center">
  <img src="docs/images/window-apps.png" width="560" alt="The Backstage window on its Apps tab: Allow every app is off, and Calendar, Finder, Music, Notes, Pages and Reminders are on the list of apps agents may use">
</p>

**Backstage is an MCP server that operates Mac apps for Claude Code, Codex or any other MCP client.** An agent reads a window as numbered elements, presses, types and drags by number, and is told exactly what changed, without bringing the app forward or moving your cursor. It runs any app's menu commands by name, manages and arranges windows across displays, and for well-known apps skips the window and uses the app's own automation instead.

- **Works behind your back, not in your way.** Tools work in the background: nothing activates an app or moves the pointer, except the few that say so and need `foreground: true` (a last-resort click, bringing a window back from the Dock, full screen). Requests for one app run one at a time, so two agents never type into each other.
- **Says what happened, not what it hopes.** Every action reports how it was delivered and what changed once the app settled, or says plainly that it could not tell.
- **Every app's commands, without exploring.** `list_menu_commands` shows what any app can do, with its keyboard shortcuts, and `run_menu_command` runs a command by its menu path. It works in apps Backstage has never seen and keeps working when an app changes its layout.
- **Windows as objects.** List every window on every display, move, resize and arrange them in halves, quarters or thirds, minimize, hide, close and quit, each change read back.
- **Ready operations for Apple's apps.** Notes, Reminders, Calendar, Contacts, Mail, Messages, Music, Finder, Pages, Numbers, Shortcuts and System Settings have typed operations that run while the app is hidden or closed, most of them also while the screen is locked, and that read their result back where the app allows it.
- **You decide which apps.** Agents can use only the apps on your list. Nothing asks during a task, so unattended sessions stay within what you chose; Passwords, Keychain Access and login windows are never available.
- **Local and independent.** No account, no telemetry, no dependency on any AI product. Everything is Swift: a small command speaks MCP, and a signed helper app does the work through Accessibility, the window server, Apple events, EventKit and the Contacts framework.

## Install

### Requirements

- A Mac with Apple silicon and macOS 26 or newer (the two latest versions). The app goes into `/Applications`, or into `~/Applications` for an account that cannot write there.
- The Xcode command line tools (`xcode-select --install`) to build it. Xcode itself is needed only for the tests.
- An MCP client: setup registers with Claude Code and Codex, and prints the configuration for any other.

### Setup

With Homebrew:

```sh
brew install padmk/tap/backstage
backstage setup
```

From a checkout:

```sh
git clone https://github.com/padmk/backstage
cd backstage
make install
```

Homebrew builds the app from source; `make install` builds `build/Backstage.app` with Swift Package Manager. Either way, `setup`:

1. Installs the app into `/Applications` (or `~/Applications`), signed with a certificate of this Mac (see below).
2. Opens System Settings and waits up to 3 minutes for you to enable Backstage under **Accessibility**, the one permission it needs. If it is not listed, drag it there from the Finder window setup opens.
3. Registers `/Applications/Backstage.app/Contents/Helpers/backstage mcp` as the `backstage` MCP server with Claude Code and Codex, when they are installed, and prints the configuration for other clients.
4. On the first install, opens the Backstage window on the Apps tab, where you choose the apps agents may use. An update opens nothing.

| Command | Effect |
|---|---|
| `make app` | Build `build/Backstage.app` only, signed ad hoc |
| `build/Backstage.app/Contents/Helpers/backstage setup --no-register` | Install without registering with Claude Code or Codex |

**Screen Recording** is optional. Only `screenshot` (and `get_window_state` with `screenshot: true`) uses it, for web pages and apps that show no elements. Turn it on later on the Setup tab.

**The `backstage` command** lives inside the app, at `/Applications/Backstage.app/Contents/Helpers/backstage`; MCP clients run it with `mcp`. To use it from a shell by name, link it onto your `PATH`, for example `ln -s /Applications/Backstage.app/Contents/Helpers/backstage ~/.local/bin/backstage`.

**Signing and updates.** macOS ties permissions to the app's signature. The first setup creates a certificate of this Mac in a keychain of its own and signs the installed app with it, so the permissions survive updates without a paid Apple developer account, as long as the certificate stays. Note that any process running as you can use that certificate; [SECURITY.md](SECURITY.md#signing) explains what that means. To update, run `brew upgrade backstage` (or pull and `make install`), then `backstage setup`. Running client sessions move to the new version on their next request; element numbers from before then need a new read. Nothing changes the installed app but an explicit setup.

**Uninstall.** `backstage uninstall` quits the app, turns off its login item, removes its MCP registrations and moves it to the Trash; the app list, settings and certificate stay for a later install. `backstage uninstall --reset` removes those too, after asking, and resets its macOS permissions. With Homebrew, run it before `brew uninstall backstage`, which does not touch the copy in Applications.

Files live at the XDG defaults: the app list in `~/.config/backstage`, the signing keychain in `~/.local/share/backstage`, the activity log and socket in `~/.local/state/backstage`.

## See it work

A read of a window, as an agent gets it from `get_window_state` (the fixture app from the live test, shortened):

```text
app="CUA Fixture" windows=[0*:"Fixture Main" 1:"Fixture Other"]
1 Window(StandardWindow) "Fixture Main"
  2 Button "Press Me" focused [Press]
  3 StaticText value="presses: 0"
  4 TextField placeholder="Plain" id="plain-field" editable [ShowMenu,Confirm]
  5 TextField secure placeholder="Secret" editable [ShowMenu,Confirm]
  6 Slider value="10" editable [Increment,Decrement]
  8 Button "Open Sheet" [Press]
```

`press` with `element: 2` presses the button in the background and replies with what changed once the app settled:

```json
{ "delivery": "accessibility", "action": "AXPress",
  "state": { "changed": true, "removed": ["3 StaticText value=\"presses: 0\""], "added": ["3 StaticText value=\"presses: 1\""] } }
```

For an app with ready operations the window is not needed at all. `run_operation` with `app: "Reminders"`, `operation: "list_lists"`:

```json
{ "operation": "list_lists", "lists": [{ "id": "A2560CE3-…", "title": "Inbox", "account": "iCloud", "default": true, "writable": true }, …] }
```

## For AI agents

If you are an agent asked to install Backstage: follow [Setup](#setup). It needs the user at the keyboard once, to enable Accessibility in System Settings and to choose apps on the Apps tab; say so, and do not try to grant permissions or change the app list yourself.

If you are an agent using Backstage, this is the shortest path to doing it well:

1. **Check access first.** Call `list_apps` (with `app` for one that is not running). Use an app only when its `access` is `allowed`, by any route, including osascript and other tools. If it is not, tell the user which app to add on the Apps tab and carry on with the rest.
2. **Prefer ready operations, then menu commands.** Call `list_operations` with the app. If an operation fits, `run_operation` is faster than the window, works in the background and checks its own result. Otherwise `list_menu_commands` (with `query`) shows what the app can do; `run_menu_command` runs it.
3. **Read, act by number, check `state`.** `get_window_state`, then `press`, `set_value`, `type_text` or `select_text` with the element number. Read `state` in the reply: it lists what changed. `verified: false` or `state.unknown` means look again before going on.
4. **Use pixels only when there are no elements.** For web content and custom views, `screenshot` then `click_at` with window coordinates.
5. **Wait instead of polling.** After an action that takes time, `wait_for` the text that shows when it is done (or `gone: true` for a progress bar).
6. **Never retry a change blindly.** `outcome_unknown` means it may have happened: read the state first. Messages `send` cannot be undone.
7. **On a locked screen** (`screen_locked` in `list_apps`), use ready operations and the menu bar; never try to unlock the Mac. See [Locked screen](#locked-screen).

The server repeats the essentials in its MCP instructions, so a client that loads them gets the same rules. Every error code and what to do about it is in [Errors](#errors).

## Tools

| Tool | What it does |
|---|---|
| `list_apps` | Lists running apps with whether agents may use each one (`allowed`, `not_approved`, `never_available`); with `app`, checks one app without starting it. Also reports `screen_locked` and `windows_while_locked` |
| `launch_app` | Starts an app by name or bundle id in the background, giving the focus back if it takes it while starting; leaves an app that is already running as it is |
| `list_operations` | Lists the ready operations, hints and pitfalls known for well-known apps; with `app`, that app's operations and their arguments. Needs no approval |
| `run_operation` | Runs one of them through the app's own automation surface, in the background, and reports whether its result was read back (`verified`) |
| `get_window_state` | Reads a window, the menu bar (`menu_bar`), the app's items on the right of the menu bar (`menu_extras`) or a subtree (`root`) as numbered elements. Reading the same place again returns only what changed since the last read or action there; `full: true` returns everything, `screenshot: true` adds a screenshot of the window |
| `press` | Presses an element or runs one of the actions it lists; a list row, or the text in one, is selected |
| `set_value` | Replaces an element's value |
| `type_text` | Inserts text at an element, or sends it as keys to the focused element |
| `select_text` | Selects text in a field or document by what it says, or puts the cursor before or after it, so `type_text` replaces or inserts exactly there |
| `press_key` | Sends a key or combination, such as `return` or `cmd+s` |
| `scroll` | Scrolls the area containing an element |
| `drag` | Drags from one element or point to another in the background, without moving the cursor |
| `read_text` | Reads the full text of an element, or a range of it, where the tree cuts a long value or label (marked `length=` or `label_length=`). An element without a text value, such as a chat message, gives its label |
| `screenshot` | Captures a window as a PNG, one pixel per window point, so its coordinates work with `click_at` |
| `click_at` | Sends a click at a point in a window or at an element's center, with any button and held modifiers (right-click, cmd-click); with `foreground: true` brings the window forward for that click as a last resort |
| `list_windows` | Lists windows across apps and displays: id, app, frame, display, on screen, Space (`current`, `other`, `unknown`); for apps on your list also the title, window number, minimized, full screen, modal, movable and resizable. Displays come with their frame and visible area |
| `set_window` | Changes one window in one way: `frame`, `layout` (halves, quarters, thirds, `maximize`, `center`, on any display), `minimized` or `fullscreen`; reads the frame back and says when the app kept it within its own limits |
| `set_app_state` | Hides an app, or shows it again without bringing it forward |
| `close` | Closes a window through its close button, or quits the app (`quit: true`) as if you chose Quit; never forced |
| `list_menu_commands` | Lists an app's menu commands with their path, shortcut, enabled state and element number, without opening a menu |
| `run_menu_command` | Runs one menu command by its path (`File > Export…`) or shortcut (`cmd+shift+s`), without opening the menu or typing the keys |
| `wait_for` | Waits until text shows in a window, or until it is gone, up to 30 s |
| `run_actions` | Runs up to 20 of the actions above in one app in order and reports the combined change once; stops at the first step that fails or may have worked, while a step delivered but not confirmable (`verified: false`) does not stop the others |

### Action replies

Every action reply says how it was delivered and what changed:

```json
{ "delivery": "pointer_event", "verified": false, "state": { "changed": true, "added": ["7 Button \"Save\""], "removed": [] } }
```

- `delivery`: `accessibility`, `value_appended_at_end` (an unfocused one-line field took the text at its end, ignoring the cursor), `key_events`, `pointer_event` or `foreground_pointer_event`.
- `verified`: `true` when the helper read the result back (a value it set), `false` when delivery could not be confirmed, so check the effect before going on. Absent when the action itself is the confirmation, such as an accessibility press, which macOS accepts or refuses.
- `state`: the difference from the last read of this app, taken once the app has settled: its Accessibility notifications have paused and a read shortly after shows the same (up to 5 s, while a new busy indicator shows; see [docs/architecture.md](docs/architecture.md)). `settled: false` means it was still changing. `{ "unknown": true, "reason": "..." }` means it cannot tell, for example when the window closed. Changes outside the area last read do not show. A value longer than 300 characters shows its start, its `length` and a `digest` of all of it, so a change anywhere in it shows as a changed line; read the rest with `read_text`. A label longer than 300 characters shows its start and `label_length`.
- `focus_returned: true`: the app brought itself forward in response, and the helper gave the focus back to the app you were in.

Requests for the same app run one at a time, also across agents, so two sessions never interleave their input in one app.

### Errors

| Code | Meaning | What to do |
|---|---|---|
| `not_approved` | The app is not on the user's list | Ask the user to add it on the Apps tab; do not reach it another way |
| `not_allowed` | Never available: the app (Passwords, Keychain Access, login windows, Backstage), an item in the Apple, Services or Share menu, or what an operation's rules refuse (a read-only calendar, a recurring event, a file outside your home folder or in its Library, a locked note) | Change the arguments, or ask the user to do it |
| `permission_missing` | A macOS grant is missing (Accessibility, Screen Recording, or one a ready operation needs) | Ask the user to allow it on the Setup tab |
| `access_denied` | The user declined that grant | The message names the pane in System Settings |
| `screen_locked` | The screen is locked, so windows cannot be read | Use ready operations or the menu bar; see [Locked screen](#locked-screen) |
| `user_active` | The app is in front and the user typed or clicked in the last 2 s | Try again in a few seconds |
| `outcome_unknown` | The action or operation may have worked, for example it opened a blocking dialog or was cancelled midway | Read the state before trying again; never retry blindly |
| `stale_element`, `unknown_element` | The element number no longer names what was read | Read the window again |
| `stale_window` | A window id from `list_windows` now belongs to another app | List the windows again |
| `needs_foreground` | The change would bring a window in front (back from the Dock, full screen) | Pass `foreground: true` if that is what the user wants, and tell them |
| `disabled` | The menu command is disabled now, often because the app has no key window in the background | Use a ready operation, or ask the user |
| `helper_stopped` | The app quit or restarted while a request ran; it may or may not have run | Read the state before trying again |
| `busy`, `request_too_large` | Too many requests are waiting on one connection, or one is larger than 4 MB | Wait for answers; send less at once |
| `unknown_app`, `unknown_operation`, `unknown_method` | No ready operations for that app, no such operation, or no such request | Check `list_operations` and the tool name |
| `store_failed` | The app list could not be saved | Tell the user |
| `unsupported_format` | WhatsApp keeps its data in a format Backstage does not know, usually after an update | Read the chat through the window |
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
| Messages | `list_chats` (with `query`), `read_chat` (latest messages, a time range, or earlier ones with `before`), `save_attachment`, `send`. Reading needs Full Disk Access (the Messages history grant); without it `list_chats` uses scripting and conversations are read through the window |
| WhatsApp | `list_chats` (with `query`), `read_chat` (latest messages, or a time range; earlier ones with `before`), `save_media` (copies a photo or document to a temporary file); read from WhatsApp's data on this Mac, without its window. Needs Full Disk Access |
| Finder | `selection`, `front_folder`, `reveal`, `get_tags`, `set_tags`, `trash` |
| Pages | `list_documents`, `open`, `read_text`, `export_pdf`, `close` |
| Numbers | `list_documents`, `open`, `read_table` (from any row), `set_cell`, `set_cells`, `export_pdf`, `close` |
| Home | Hints and pitfalls for its window |

`get_window_state` shows an app's hints and pitfalls under its first line. Operations need the app to be allowed, like the other tools, and some need a macOS grant: Automation of the app, or Reminders, Calendars or Contacts. macOS asks once, when you add the app on the Apps tab, and never for an app that is not on the list. WhatsApp's operations and reading Messages need Full Disk Access, which macOS never asks for: the Setup tab opens its pane with a panel to drag Backstage into the list. An operation never shows that prompt during a task: without the grant it fails with `permission_missing`. `outcome_unknown` means a change may have been made: read before trying again. Contracts (ids, dates, paths, limits), the reasoning behind them and the measurements are in [docs/app-knowledge.md](docs/app-knowledge.md).

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
| The menu bar: `get_window_state` with `menu_bar` or `menu_extras`, `press` on its items, `list_menu_commands` and `run_menu_command` | Works |
| `list_windows` | Lists windows from the window server, without titles or states |
| `set_app_state` (hide, show) | Works |
| Window trees, element actions, `set_window`, `close`, `wait_for` on a window | Stop with `screen_locked` |
| Messages `send` | Sends, but cannot confirm it (`verified: false`); do not send again |
| `screenshot`, `click_at` with `x` and `y`, `press_key`, `type_text` without an element | Only with **Windows while locked** on, from screenshots and never verified |

**Windows while locked** is off by default, on the Setup tab. It captures windows with a private window server call and posts clicks and keys to the app, which keeps working while macOS hides windows from its public interfaces. It is useful for window work that ready operations do not cover while you are away, at the cost of verification, of relying on undocumented behavior, and of reaching past a protection macOS applies on purpose. [docs/locked-screen.md](docs/locked-screen.md) explains what changes when the screen locks, how the mode works, its advantages, costs and limits, and the measurements.

## The Backstage window

Open **Backstage** from `/Applications` to see and change everything in one window, with three tabs:

<p align="center">
  <img src="docs/images/window-setup.png" width="420" alt="The Setup tab: Open at login, Show in menu bar and Windows while locked under Background, Accessibility and Screen Recording allowed, and the macOS grants the listed apps use">
  <img src="docs/images/window-activity.png" width="420" alt="The Activity tab: which agent first used which app, and changes to the list and the switches, with relative times">
</p>

- **Apps:** apps asked for from the command line or by an agent, waiting for you to add or decline them; Allow every app, and otherwise the list of apps agents may use, with Add App… and Remove. Far-reaching apps carry their warning. While Allow every app is on, the list folds away and is kept for when it goes off. While an app's ready operations wait for a macOS grant, a line here leads to Setup, and the Setup tab carries a dot.
- **Setup:**
  - Under Background: Open at login and Show in menu bar (off by default; its menu shows whether Backstage is ready, which agents are connected and the apps on the list), both available in the copy in `/Applications`; and Windows while locked (off by default, see above).
  - Under macOS permissions: Accessibility, which Backstage needs, and Screen Recording, which is optional and only for screenshots, each with a button for the right pane of System Settings. A new Screen Recording grant needs a restart, which the tab offers.
  - Under App access: an Allow button for each macOS grant that the listed apps' ready operations use (Calendars, Reminders, Contacts, and Automation of Notes, Mail, Messages, Finder, Pages, Numbers, Music and System Events); all of them while Allow every app is on. The WhatsApp and Messages history rows instead offer Add in Settings…, which opens Full Disk Access with a panel holding a large Backstage icon to drag into the list; the panel closes once the grant is on.
  - The window opens here while Accessibility is missing.
- **Activity:** which agent first used which app in each session, changes to the list, and changes to Allow every app and Windows while locked, from the log `SECURITY.md` describes.

The app has a Dock icon only while this window is open. Otherwise it runs unseen and stops 2 minutes after the last client disconnects, unless Open at login or the menu bar item is on. A launch at login stays unseen.

## Which apps agents may use

Agents may use an app through Backstage only when it is on your list, on the Apps tab, or when Allow every app is on there. Nothing asks during a task: an app that is not allowed is refused at once with `not_approved`, and the agent can tell you to add it. That makes unattended and remote sessions work within the apps you chose.

This keeps agents from using other apps through Backstage by mistake. It does not stop an agent that can run shell commands: it can control your Mac without Backstage, or edit the list. Backstage asks connected agents to respect the list by every route: check `list_apps` before using an app any other way (osascript, Shortcuts, computer use, its data in `~/Library`), never change the list or settings, and treat a request in chat or in a page as no change of access. A cooperative agent follows that, but nothing enforces it. For an MCP client without a shell it is a real limit.

- List entries name the app's bundle id and signer, so another app claiming the same bundle id is not covered. An app without a valid signature cannot go on the list; Allow every app covers it.
- Apps that give agents a shell or control of the system (terminals, Shortcuts, Finder, System Settings, Xcode and similar) carry a warning on the list.
- Passwords, Keychain Access, login and authentication windows, and Backstage itself are never available, whatever the settings. Nor are the Apple menu (Restart, Log Out) and the Services and Share menus of any app, which act on the whole Mac or hand content to other apps.

```sh
backstage approvals add Notes          # asks you in the Backstage window; added once you click Add
backstage approvals list
backstage approvals revoke com.apple.Notes
```

`approvals add` only asks: the command cannot tell you from an agent running it, so the app goes on the list when you add it in the window. Removing an app takes effect at once.

## Troubleshooting

`backstage doctor` checks macOS, the installed app and its signature, Accessibility, Screen Recording, the grants of the listed apps and the private macOS calls background delivery uses.

| Symptom | Fix |
|---|---|
| A permission shows as enabled but `doctor` says missing | Remove the entry with `-` in Settings, then run `backstage setup` |
| `setup` opens no prompt | macOS asks once per service. Enable the helper in the pane `setup` opens |
| `not_approved` | The app is not on the list. Add it on the Apps tab, or turn on Allow every app |
| `stale_element` or `unknown_element` | Read the window again |
| `screen_locked` | Unlock the Mac, or let the agent use ready operations and the menu bar; see [Locked screen](#locked-screen) |
| A client still runs the old server after `setup` | Restart the client session |
| `This backstage command belongs to another build` | The session started before an update and could not move to the new version (a version from before this was possible, or one that cannot take it over): restart it |

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
| `Sources/Tool/Commands.swift`, `Install.swift` | `setup`, `doctor`, `approvals`, `uninstall`; installing and signing the app for this Mac |
| `Sources/App/HelperMain.swift`, `Server.swift` | The app's start, the Unix socket and sessions |
| `Sources/App/Requests.swift` | The request router |
| `Sources/App/Apps.swift`, `Actions.swift` | Finding and starting apps; reading windows and acting on them |
| `Sources/App/Observation.swift`, `Sequences.swift` | Change reports after actions, the per-app lock, and `run_actions` |
| `Sources/App/Presence.swift`, `LockedWindows.swift` | The user working in the target app; the locked screen and Windows while locked |
| `Sources/App/WindowManagement.swift` | `list_windows`, `set_window`, `set_app_state`, `close`: displays, frames, layouts |
| `Sources/App/MenuCommands.swift`, `MenuSafety.swift` | Menu commands with their shortcuts; the Apple, Services and Share menus refused on every route |
| `Sources/App/WaitFor.swift` | `wait_for` |
| `Sources/App/ApprovalRequests.swift` | Apps asked for over the socket, waiting for the user in the window |
| `packaging/homebrew/backstage.rb` | The formula for the tap, filled in at each release |
| `Sources/App/apps/` | App knowledge: the catalog (`Catalog.swift`), the script runner and event store, one file per app |
| `Sources/App/Approvals.swift` | The app list and the check every request passes |
| `Sources/App/window/`, `Theme.swift` | The Backstage window, one file per tab, its model, texts and look |
| `Sources/App/MenuBar.swift`, `LaunchAtLogin.swift`, `Preferences.swift` | The menu bar item, starting at login and the settings behind them |
| `Sources/App/Accessibility.swift`, `Tree.swift` | Reading apps and numbering elements |
| `Sources/App/Input.swift`, `BackgroundEvents.swift`, `Capture.swift` | Key and pointer events, background delivery, screenshots |
| `Tests/ToolTests/` | Protocol, app, live and benchmark tests; `Tests/Fixtures/target` is the test app |

## Documentation

| Document | What it covers |
|---|---|
| [docs/architecture.md](docs/architecture.md) | The parts, a request step by step, background input, verification, and the reasoning behind the design |
| [docs/locked-screen.md](docs/locked-screen.md) | What changes when the screen locks and why, what still works, and the Windows while locked mode with its costs and limits |
| [docs/app-knowledge.md](docs/app-knowledge.md) | Ready operations: routes, contracts, how each proves it worked, scope and measurements |
| [SECURITY.md](SECURITY.md) | The security model, what it does not protect against, private macOS calls and signing |
| [PRIVACY.md](PRIVACY.md) | What leaves the Mac and what stays on disk |
| [bench/README.md](bench/README.md) | Latency measurements |
| [CHANGELOG.md](CHANGELOG.md) | Changes |

## License

MIT. The app icon was made for Backstage and is covered by the same license.

Apple, macOS and the names of Apple's apps are trademarks of Apple Inc.; Claude Code is a product of Anthropic and Codex of OpenAI. Backstage is an independent project, not affiliated with or endorsed by them.
