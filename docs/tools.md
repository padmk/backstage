# Tools

Backstage serves 24 MCP tools over stdio. This page lists each one with its arguments and defaults, what an action replies, and every error code an agent can get. The tool definitions live in `Sources/Tool/Tools.swift`; the server checks every call against them before it reaches an app.

## Using them well

If you are an agent asked to install Backstage: follow [Install](install.md). It needs the user at the keyboard once, to enable Accessibility in System Settings and to choose apps on the Apps tab; say so, and do not try to grant permissions or change the app list yourself.

If you are an agent using Backstage, this is the shortest path to doing it well:

1. **Check access first.** Call `list_apps` (with `app` for one that is not running). Use an app only when its `access` is `allowed`, by any route, including osascript and other tools. If it is not, tell the user which app to add on the Apps tab and carry on with the rest.
2. **Prefer ready operations, then menu commands.** Call `list_operations` with the app. If an operation fits, `run_operation` is faster than the window, works in the background and checks its own result. Otherwise `list_menu_commands` (with `query`) shows what the app can do; `run_menu_command` runs it.
3. **Read, act by number, check `state`.** `get_window_state`, then `press`, `set_value`, `type_text` or `select_text` with the element number. Read `state` in the reply: it lists what changed. `verified: false` or `state.unknown` means look again before going on.
4. **Use pixels only when there are no elements.** For web content, canvases, remote desktops and other custom views, `screenshot` then `click_at` with window coordinates. `screenshot` with `text: true` also lists the text it recognizes in the image, with each line's frame in the same coordinates:

   ```json
   { "width": 900, "height": 600, "png_base64": "…", "title": "Board",
     "text": [ { "text": "Sprint 12", "confidence": 1, "frame": [24, 18, 96, 20] },
               { "text": "Add card", "confidence": 0.98, "frame": [40, 520, 70, 16] } ] }
   ```

   A click at the middle of a frame (`x` + `width` / 2, `y` + `height` / 2) lands on that text. Recognized text can be misread and is only an observation: check the effect with another screenshot.
5. **Wait instead of polling.** After an action that takes time, `wait_for` the text that shows when it is done (or `gone: true` for a progress bar).
6. **Never retry a change blindly.** `outcome_unknown` means it may have happened: read the state first. Messages `send` cannot be undone.
7. **Close what you open.** Menus, pop-up buttons, popovers and palettes an action opens show on the user's screen above their work, even with the app in the background. Choose the item or close them with `press_key` `escape` before you move on or end.
8. **Start apps with `launch_app`,** not `open` in a shell, which brings the app forward and takes the user's focus.
9. **On a locked screen** (`screen_locked` in `list_apps`), use ready operations and the menu bar; never try to unlock the Mac. See [Working while the screen is locked](locked-screen.md).

The server repeats the essentials in its MCP instructions, so a client that loads them gets the same rules.

## Common arguments

- `app`: the app's name, bundle id or process id. `list_apps`, `launch_app`, `list_operations` and `run_operation` take a name or bundle id only; `launch_app` never takes a path.
- `window`: the window index shown on the first line of `get_window_state`, from 0; default the first window.
- `element`: an element number from `get_window_state`. Numbers belong to one session and one app and stay valid across reads in that session. A new session numbers elements anew. Each new connection of a session, as after the helper restarted, and each move to a new build after an update gets numbers from a range of its own, so older numbers fail with `unknown_element` instead of naming another element; a helper that kept the session keeps its numbering.

## The tools

Arguments in the second column are optional unless marked required.

Each tool tells MCP clients what it may do, so a client can decide what to allow without asking: the tools that only read (`list_apps`, `list_operations`, `get_window_state`, `read_text`, `screenshot`, `list_windows`, `list_menu_commands`, `wait_for`) are marked read-only; those that send input or run what an app offers (`press`, `set_value`, `type_text`, `press_key`, `drag`, `click_at`, `run_actions`, `run_operation`, `run_menu_command`, `close`) are marked destructive, since they can replace or delete what an app holds; `launch_app`, `select_text`, `scroll`, `set_window`, `set_app_state` and `record_audio` change only what is shown or started.

### Apps and ready operations

| Tool | Arguments | What it does |
|---|---|---|
| `list_apps` | `app` | Lists running apps with `access` for each: `allowed`, `not_approved` (not on the user's list) or `never_available`. With `app`, that one app, running or only installed, without starting it; the bundle id of a never-available app answers `never_available` even when this Mac does not have it. Also reports `every_app`, `screen_locked` and `windows_while_locked` (the user's setting). Being listed does not allow an app |
| `launch_app` | `app` (required, name or bundle id), `files` (1 to 20 absolute paths) | Starts an app in the background, giving the focus back if it takes it while starting; an app that is already running and gets no files is left as it is. With `files`, hands the app files to open: the user's own reachable files, or copies Backstage made, such as `record_audio`'s recordings. Needs the app on the list |
| `list_operations` | `app` | Without `app`, every app with ready operations or hints, with a summary each. With `app`, its operations and their arguments, hints and pitfalls. Needs no approval: it is static knowledge and touches no app |
| `run_operation` | `app`, `operation` (both required), `arguments` (object) | Runs one ready operation through the app's own automation surface, in the background. The reply carries the result and, for a change, `verified`. The helper checks the arguments and names the whole argument list when one is wrong |

The apps with ready operations and the operations themselves are in [App knowledge](app-knowledge.md#operations).

### Reading

| Tool | Arguments | What it does |
|---|---|---|
| `get_window_state` | `app` (required), `window`, `full`, `screenshot`, `menu_bar`, `menu_extras`, `root` (element), `max_elements` (1 to 5000, default 800) | Reads a window, the menu bar (`menu_bar`), the app's items on the right of the menu bar (`menu_extras`) or one element's subtree (`root`) as numbered lines with role, labels, value and actions. The first line lists the app's windows, and the app's hints and pitfalls follow it. Reading the same place again returns only what changed since the last read or action there; `full: true` returns everything. `screenshot: true` adds a PNG of the window (needs Screen Recording). A read cut at `max_elements` is partial, and an action after it cannot report what changed; read less with `root` |
| `read_text` | `app`, `element` (both required), `start` (from 0), `length` (1 to 50,000, default all up to 50,000) | Reads the full text of an element, or part of it, where the tree cuts a long value or label (marked `length=` or `label_length=`). An element without a text value gives its label, and `source` says which. Positions count UTF-16 units, like `select_text`; the reply gives the total and whether more follows |
| `screenshot` | `app` (required), `window`, `text` (default false) | Captures a window as a PNG, one image pixel per window point, so its coordinates work with `click_at`. Needs Screen Recording, which is optional: without it the reply is `permission_missing` and the Backstage window shows the user an Allow button. With `text: true` the reply also has `text`: the lines Apple's Vision framework recognizes in the image on this Mac, each with `text`, `confidence` (0 to 1) and `frame` as `[x, y, width, height]` in window points from the window's top left, top to bottom and left to right, at most 200, with `text_truncated: true` when cut. When recognition fails or runs out of time, the image still comes back, with `text_error` (a code and a message) instead of `text`. The first recognition after the helper starts loads Vision's models and can take about 15 seconds; later ones take a fraction of a second. Recognized text can be wrong; nothing clicks by it, and it is not part of change reports, element numbers or `wait_for`, so a change in it does not prove that an action worked. `get_window_state` with `screenshot: true` does not recognize text |

### Acting on elements and points

| Tool | Arguments | What it does |
|---|---|---|
| `press` | `app`, `element` (both required), `action` (an action the element lists, such as `ShowMenu`; default press) | Presses an element without taking focus, or runs one of its actions. A list row without actions, or the text in one, is selected |
| `set_value` | `app`, `element`, `value` (all required) | Replaces the value of an editable element |
| `type_text` | `app`, `text` (both required, up to 100,000 characters), `element` | Inserts text at an element, or without one sends it as keys to the app's focused element. Line breaks and tabs need an element that takes text directly; otherwise send them with `press_key`. Nothing is typed if the element cannot take it |
| `select_text` | `app`, `element`, `text` (all required), `prefix`, `suffix`, `place` (`select`, `before` or `after`; default `select`) | Selects text in a field or document by what it says, or puts the cursor just before or after it, so `type_text` replaces or inserts exactly there. When the text occurs more than once, `prefix` or `suffix` picks one occurrence |
| `press_key` | `app`, `key` (both required), such as `return` or `cmd+s` | Sends a key or combination to the app in the background. A native view receives it once it has focus, so click the view with `click_at` first; prefer pressing the menu item where there is one. See [Keys and shortcuts](#keys-and-shortcuts) for what is refused |
| `scroll` | `app`, `element`, `direction` (`up`, `down`, `left`, `right`; all required), `pages` (1 to 20, default 1) | Scrolls the area containing an element by `pages`: by moving its scroll bar by the visible share of the content, so one page is about one screenful, or through the area's own page actions where it has no scroll bar. When neither is known, a vertical scroll posts a wheel event (`verified: false`) and a horizontal one fails with `action_failed` |
| `drag` | `app` (required), `window`, `from_element` or `from_x` and `from_y`, `to_element` or `to_x` and `to_y` | Drags from one place to another in the background, without moving the cursor: a slider's knob, an item onto a target, a selection. Each end is an element's center or a point in window coordinates |
| `click_at` | `app` (required), `element` or `x` and `y`, `window`, `count` (1 to 3, default 1), `button` (`left`, `right`, `middle`; default left), `modifiers` (`cmd`, `shift`, `alt`, `ctrl`), `foreground` | Sends a click at a point in window coordinates or at an element's center, in the background and without moving the cursor: a right-click, a cmd-click, a view without elements. `foreground: true` is the last resort when a background click did not land: the window comes forward for that click, then the previous app gets the focus back and the cursor returns. Tell the user when you use it |
| `run_actions` | `app`, `steps` (both required, 1 to 20) | Runs up to 20 steps in one app in order and reports the combined change once. Each step is `{"tool": ..., ...}` with one of `press`, `set_value`, `type_text`, `select_text`, `press_key`, `scroll`, `drag` or `click_at` and that tool's arguments without `app`. Every step's tool name and arguments are checked before the first step runs. Steps stop at the first that fails or may have worked (`failed` names it); a step that was delivered but cannot be confirmed (`verified: false`) does not stop the others. Elements a step makes appear have no number yet |

### Windows

| Tool | Arguments | What it does |
|---|---|---|
| `list_windows` | `app` (only this app's windows) | Lists windows across apps and displays: id, app, bundle id, `access`, frame (global points, origin at the top left of the main display), display, front-to-back index, on screen, and Space (`current`, `other`, `unknown`). For apps on the user's list it adds the title, the window index, minimized, full screen, modal, movable and resizable. Displays come with their frame and visible area (without the menu bar and the Dock), and the reply names the front app |
| `set_window` | `app` (required), `id` or `window`, exactly one of `frame` (`{x, y, width, height}`), `layout`, `minimized`, `fullscreen`; `display` (with `layout`: a display id, `next` or `previous`), `foreground` | Changes one window in one way. `layout` is `maximize`, `center`, a half (`left_half`, `right_half`, `top_half`, `bottom_half`), a quarter (`top_left`, `top_right`, `bottom_left`, `bottom_right`) or a third (`left_third`, `center_third`, `right_third`, `left_two_thirds`, `right_two_thirds`) of a display's visible area. The reply reads the frame back: `verified` within 2 points, `adjusted` when the app kept it within its own limits. Bringing a window back from the Dock or into full screen needs `foreground: true`. Windows on another Space cannot be changed |
| `set_app_state` | `app`, `state` (`hidden` or `shown`; both required) | Hides an app's windows, or shows them again without bringing the app forward |
| `close` | `app` (required), `id` or `window`, `quit` | Closes a window through its close button, or quits the app (`quit: true`) as if the user chose Quit. A window counts as closed once the window server or the app no longer lists it, or once it was drawn and no longer is while not minimized, as with apps that keep a closed window hidden, such as Music. Nothing is forced: when the app asks about unsaved work, or the window stays, the reply is `outcome_unknown` |

### Menus

| Tool | Arguments | What it does |
|---|---|---|
| `list_menu_commands` | `app` (required), `query`, `enabled_only`, `max` (1 to 2000, default 300) | Lists the app's menu commands with their path (`File > Export…`), keyboard shortcut, enabled state and element number, without opening a menu. `query` keeps commands whose path or shortcut contains it. The Apple, Services and Share menus are left out |
| `run_menu_command` | `app` (required), `command` (a path separated by `>`, or the last title alone when it is unique) or `shortcut` (such as `cmd+shift+s`) | Runs one menu command in the background, without opening the menu or typing the keys. A path that starts with its menu (`File > Export…`) reads only that menu. A disabled or ambiguous command is refused, with the matches. When the menus cannot be read in time, nothing runs and the reply is `timeout`; give the whole path from its menu. A toggle is verified by its checkmark |

Commands that act on the current document (Save, Duplicate) are disabled while the app is in the background, because it has no key window.

### Keys and shortcuts

`press_key`'s `key` and `run_menu_command`'s `shortcut` name modifiers as `cmd` (also `command` or `super`), `alt` (`option`), `ctrl` (`control`) and `shift`, joined with `+`. A trailing `+` is the plus key (`cmd++`). Key names ignore case and underscores (`page_up` is `pageup`), and `enter`, `esc` and `backspace` name return, escape and delete. `click_at` takes the four modifiers `cmd`, `shift`, `alt` and `ctrl`.

`press_key` refuses with `not_allowed` a shortcut of an item in the Apple, Services or Share menu, and return or space while such an item is selected in an open menu. `type_text` refuses text with a space with `not_allowed` while the app shows a menu, where a space would confirm the selected item; close the menu first, or choose the item with `press`. A combination with `cmd` or `ctrl` is checked against the Apple menu's fixed shortcuts (such as shift+cmd+Q) and against the shortcuts of the items in the app's Apple menu, the Services submenu of its app menu, and Services or Share submenus directly under a top-level menu; the rest of the menu bar is not read. When those menus cannot be read within about a second, the key is not sent and the reply is `timeout`; try again in a moment. The routes that are checked and the gaps are in [SECURITY.md](../SECURITY.md#design).

### Waiting and recording

| Tool | Arguments | What it does |
|---|---|---|
| `wait_for` | `app`, `text` (both required), `role`, `gone`, `timeout` (0.5 to 30 s, default 10), `window`, `menu_bar`, `root` | Waits until text shows in the place `get_window_state` reads, or with `gone: true` until it stops showing. `role` limits it to elements of one role or subrole, such as `Button` or `Sheet`. The reply says whether it was found and gives the matching line, preferring one whose title or value is exactly the text |
| `record_audio` | `app` (required), `press` (element), `seconds` (1 to 180, default 60), `until_silent` (0.5 to 30 s, default 3) | Records what the app and its helper processes play into an `.m4a` file, muted for the user, for example a voice message that cannot be downloaded. `press` names the element that starts playback, pressed once the recording runs. It ends after `until_silent` seconds without sound once sound was heard, or at `seconds`. The recording also stops at the time the request has left before its deadline, less a reserve, for example after waiting for another request in the app (`ended: "time_limit"`); with too little time left the reply is `expired`. The reply gives the file's path, its length, `heard_sound` and how it ended (`ended`). Needs System Audio Recording. Other requests for the app wait until it ends; a playback speed set in the app applies to the recording |

## Action replies

Every action reply says how it was delivered and what changed:

```json
{ "delivery": "pointer_event", "verified": false, "state": { "changed": true, "added": ["7 Button \"Save\""], "removed": [] } }
```

- `delivery`: `accessibility`, `value_appended_at_end` (an unfocused one-line field took the text at its end, ignoring the cursor), `key_events`, `pointer_event` or `foreground_pointer_event`.
- `verified`: `true` when the helper read the result back (a value it set), `false` when delivery could not be confirmed, so check the effect before going on. Absent when the action itself is the confirmation, such as an accessibility press, which macOS accepts or refuses.
- `app_error`: a press or a menu command the app answered with an error (AX error -25200), which apps built with SwiftUI also do when a press opens or closes a sheet. The reply then has `verified: false` and `state` shows whether anything changed; when nothing did, the reply is `action_failed` instead. In `run_actions` such a step stops the steps as `outcome_unknown`.
- `state`: the difference from the last read of this app, taken once the app has settled: its Accessibility notifications have paused and a read shortly after shows the same, for up to 5 s while a new busy indicator shows (see [A request, step by step](architecture.md#a-request-step-by-step)). Its fields are `changed`, `added`, `removed` and, when they apply, `renumbered`, `more_changes`, `more_renumbered`, `settled` and `note`.
  - `changed`, `added` and `removed` cover real changes only: lines are compared without their element numbers.
  - `renumbered` lists elements that kept their content and only got a new number, as apps such as System Settings hand out new elements for unchanged ones; use the number shown there. It is present only when not empty.
  - Each list shows at most 40 lines. `more_changes: true` or `more_renumbered: true` means one was cut, and the next read of that place returns all of it.
  - `settled: false`, with a `note`, means the app was still changing. `{ "unknown": true, "reason": "..." }` means it cannot tell, for example when the window closed or the last read was partial. Changes outside the area last read do not show.
  - A value or a label longer than 300 characters shows its start, its `length` or `label_length`, and a `digest` of all of it, so a change anywhere in it shows as a changed line; read the rest with `read_text`.
- `focus_returned: true`: the app brought itself forward in response, and the helper gave the focus back to the app the user was in.

Requests for the same app run one at a time, also across agents, so two sessions never interleave their input in one app. Actions, `run_actions`, `run_menu_command`, `record_audio`, window changes, `launch_app` with `files` and ready operations that change something in a running app are refused with `user_active` while the user works in that app.

## Errors

A failed call returns an MCP tool error whose text starts with the code, such as `not_approved: ...`, followed by a message that says what to do. A few failures of the command itself carry a message without a code, such as `Backstage is not installed. Run: backstage setup`, or a command from another build that could not hand its session over ([Troubleshooting](install.md#troubleshooting)).

| Code | Meaning | What to do |
|---|---|---|
| `not_approved` | The app is not on the user's list | Ask the user to add it on the Apps tab; do not reach it another way |
| `not_allowed` | Never available: the app (Passwords, Keychain Access, other password managers, authenticators and wallets, the system's login and permission prompts, Backstage), an item in the Apple, Services or Share menu or its shortcut, a toolbar's Share button, or what an operation's rules refuse (a read-only calendar, a recurring event, a file outside your home folder or in its Library, a locked note) | Change the arguments, or ask the user to do it |
| `permission_missing` | A macOS grant is missing (Accessibility, Screen Recording, System Audio Recording, or one a ready operation needs), or a path lies in a folder macOS keeps from Backstage, which the message names | Tell the user what to allow: for Screen Recording and System Audio Recording the window already shows them an Allow button; for a folder, System Settings > Privacy & Security > Files and Folders |
| `access_denied` | The user declined that grant | The message names the pane in System Settings |
| `screen_locked` | The screen is locked, so windows cannot be read | Use ready operations or the menu bar; see [locked-screen.md](locked-screen.md) |
| `restarting` | Backstage is restarting to pick up a permission the user just allowed: new requests are turned away from the moment the restart is planned, and it restarts once the running ones have finished | Try again in a few seconds |
| `user_active` | The app is in front and the user typed or clicked in the last 2 s, or moved the pointer or scrolled over its windows | Try again in a few seconds |
| `outcome_unknown` | The action or operation may have worked, for example it opened a blocking dialog or was cancelled midway | Read the state before trying again; never retry blindly |
| `stale_element`, `unknown_element` | The element number no longer names what was read | Read the window again |
| `stale_window` | A window id from `list_windows` now belongs to another app | List the windows again |
| `needs_foreground` | The change would bring a window in front (back from the Dock, full screen) | Pass `foreground: true` if that is what the user wants, and tell them |
| `disabled` | The menu command is disabled now, often because the app has no key window in the background | Use a ready operation, or ask the user |
| `helper_stopped` | The app quit or restarted while a request ran; it may or may not have run | Read the state before trying again |
| `busy` | Too many requests are waiting on one connection, or too many apps wait for the user in the window | Wait for answers |
| `request_too_large` | The command refused a request larger than 4 MB before sending it; other calls in flight go on | Send less at once |
| `unknown_app`, `unknown_operation`, `unknown_method` | No ready operations for that app, no such operation, or no such request | Check `list_operations` and the tool name |
| `store_failed` | The app list could not be saved | Tell the user |
| `unsupported_format` | WhatsApp keeps its data in a format Backstage does not know, usually after an update | Read the chat through the window |
| `window_not_found`, `out_of_window`, `point_covered` | No such window, a point outside it, or another window on top of the point (`foreground: true` only) | Read again and pick another target |
| `invalid_request`, `invalid_arguments`, `invalid_key` | The request is malformed; the message names the problem and, for operations, the whole argument list | Fix the call |
| `not_settable`, `no_text`, `text_not_found`, `ambiguous_text`, `ambiguous`, `not_found` | The element or item cannot do what was asked, or the target is not unique | Follow the message |
| `cancelled`, `interrupted`, `expired`, `app_changed` | The request was cancelled, waited too long, or the app stopped | Read the state, then try again if nothing changed |
| `timeout` | Something did not finish in time: a script, an app starting, a capture or an export; or the app's menus could not be read in time, so `run_menu_command` ran nothing, or `press_key` sent no shortcut because the Apple, Services and Share menus could not be checked | Read the state; for `run_menu_command`, give the whole path from its menu; for `press_key`, try again in a moment |
| `app_not_found` | The app is not running (`launch_app` starts it) or not installed, stopped while the request ran, or an app the user was asked about is no longer installed where it was | Check the name with `list_apps`, or start the app with `launch_app` |
| `action_failed` | macOS or the app refused the action | The message names the reason |
| `failed` | An unexpected system error the helper did not classify; the message is the framework's description | Read the state before trying again, and tell the user if it repeats |
| `error` | The helper answered with an error that carried no code | Read the state, then tell the user if it repeats |
