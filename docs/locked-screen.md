# Working while the screen is locked

When the Mac's screen is locked, macOS hides app windows from the interfaces Backstage normally uses. Backstage keeps doing what still works and says plainly what does not. It never unlocks the Mac, never asks for or stores the user's password, and never wakes the displays.

This page covers what changes when the screen locks, why, what Backstage does about it, and the optional **Windows while locked** mode: how it works, what it costs and where it stops.

All measurements here are from 5 November 2026, on macOS 27.2 (build 26B123) on an Apple M4 Pro, with the screen locked and both displays asleep. They came from probes run while locked and from the MCP server itself, against the CUA Fixture test app (`test/fixtures/target`), TextEdit, Notes and the apps with ready operations.

## In short

| What an agent asks for | Screen locked, default | Screen locked, Windows while locked on |
|---|---|---|
| Ready operations (`run_operation`) | Work | Work |
| `list_apps`, `list_operations`, `launch_app` | Work; `list_apps` reports `screen_locked: true` | Same |
| `get_window_state` with `menu_bar` or `menu_extras`, or with `root` inside a menu; `list_menu_commands`, `run_menu_command` | Works | Works |
| `list_windows` | Window server data only, without titles or states | Same |
| `set_app_state` (hide, show) | Works | Works |
| `press` on a menu bar item or menu item, alone or as every step of `run_actions` | Works, and reports what changed in the menu bar | Same |
| `get_window_state` of a window, `read_text`, `set_value`, `select_text`, `scroll`, `drag`, `press` on other elements, `click_at` with `element`, `set_window`, `close`, `wait_for` on a window | `screen_locked` | `screen_locked` |
| `record_audio` | Records; `press` stops with `screen_locked` unless it presses a menu item | Same |
| `screenshot` | `screen_locked` | Works, through a private window server call |
| `click_at` with `x` and `y` | `screen_locked` | Works, unverified |
| `press_key`, `type_text` without `element` | `screen_locked` | Works, unverified |
| `click_at` with `foreground: true` | `screen_locked` | `screen_locked` |

A refused request changes nothing. The `screen_locked` message names what still works, so an agent can switch routes at once instead of retrying.

## What macOS does to windows while the screen is locked

Measured per interface:

| Interface | While locked |
|---|---|
| Lock state | `CGSessionCopyCurrentDictionary()` reports `CGSSessionScreenIsLocked = 1`; the front app is `com.apple.loginwindow` |
| Window server list (`CGWindowListCopyWindowInfo` with `optionAll`) | Still lists every window with its number, title, bounds, layer and on-screen flag |
| Accessibility: `AXWindows`, `AXFocusedWindow`, `AXMainWindow` | Return the application element itself in place of each window (one entry per window), or nothing for an app whose windows were not on screen |
| Accessibility: `AXChildren` of the app | The app element repeated once per window, then the menu bar |
| Accessibility: the menu bar (`AXMenuBar`, `AXExtrasMenuBar`) | Complete: every menu and item, with titles and enabled state |
| Accessibility: `AXPress` on a menu item | Works: TextEdit's File > New opened a new document |
| Accessibility: hit testing (`AXUIElementCopyElementAtPosition`) | System-wide fails (-25200); on the app it returns the app |
| Accessibility: window elements built from a remote token (`_AXUIElementCreateWithRemoteToken`, element ids 0 to 3000) | Only the menu bar and menus; no window |
| ScreenCaptureKit (`SCShareableContent`) | Lists the windows but no display |
| ScreenCaptureKit capture (`SCScreenshotManager`) | Fails with error -3811, "Failed to start stream due to audio/video capture failure" |
| SkyLight capture (`SLSHWCaptureWindowList`, private) | Returns the window's current pixels; the image showed a counter that changed after the lock |
| Pointer events posted to the app's process, addressed to a window | Reach the window: the fixture logged a button press, a click in a view without accessibility and a click into a text field |
| Key events posted to the app's process | Reach the focused element: the fixture logged a key in a custom view and typed text in a field |
| Apple events, EventKit, Contacts framework, `shortcuts` | Work |
| Displays and idle time | Stay asleep through all of the above; the system's HID idle time kept counting, so nothing counted as user activity |

The pattern is deliberate on Apple's part: the interfaces that tell other processes *what is in a window* (Accessibility below the menu bar, ScreenCaptureKit) stop answering, while the window server itself keeps the windows, keeps drawing them and keeps routing events to them. The apps keep running. Nothing in the public API documents this; it is what the probes showed on this macOS version, and it can change with any update.

Two findings correct earlier assumptions:

- The window server does not hide windows. An earlier note said it lists none while locked; that came from a query for on-screen windows only. With `optionAll` they are all there.
- Notes and Music showed no `AXWindows` at all while TextEdit, Home, Brave and the fixture showed the app element in their place. Notes' and Music's windows were not on screen when the screen locked, so this may come from their Space rather than from the lock.

## What Backstage does while the screen is locked

### Reporting the lock

`list_apps` (both forms) and the helper's `status` carry `screen_locked`, and `list_apps` also carries `windows_while_locked`, the user's setting below. The MCP server instructions tell agents to use ready operations and menu commands while the screen is locked and never to try to unlock the Mac. The lock is read on every request, so an agent never works from a stale answer: a request that started before the lock is checked again once it holds the app's lock.

### Ready operations

Ready operations go through each app's scripting dictionary, EventKit, the Contacts framework or the `shortcuts` command, none of which needs a window. Measured while locked through the MCP server: Notes `list_folders` and `search`, Reminders `list_lists` and `list`, Calendar `list_calendars`, Contacts `search`, Mail `list_mailboxes`, Messages `list_chats`, Music `now_playing` and `list_playlists`, Finder `selection` and `front_folder`, System Settings `get_appearance`, `get_volume` and `set_volume`, and Shortcuts `list`. The other operations use the same routes and are expected to work, with these exceptions:

- **Messages `send`** sends, but confirms the message by reading the chat list in Messages' window, which cannot be read while locked. It then returns `verified: false` with a `check` that says so and tells the agent not to send again. Sending a message twice cannot be undone, so the agent must wait for the user rather than retry.
- **System Settings `open_pane`** confirms the pane by the window's title, which cannot be read while locked, so expect `verified: false` (not measured).
- **Shortcuts `run`** should work for shortcuts that need no input and show nothing (not measured). One that asks a question or shows a result waits for an answer no one can give, until its timeout.
- **A first macOS prompt cannot be answered while locked.** Operations never show one during a task anyway: a grant macOS has not asked about fails with `permission_missing`, as when unlocked.

### The menu bar

The menu bar is the one part of an app's accessibility tree that stays whole while locked, and its commands work. So `get_window_state` with `menu_bar: true` (or `menu_extras: true` for the app's status items) runs as usual, and so does `press` on a menu bar item or menu item, alone or as every step of a `run_actions`. The reply reports what changed in the menu bar: after File > New in TextEdit it showed the new document in the Window menu.

The helper decides this per element: it looks up the element number in the session's table and allows it only when its role is a menu bar, menu bar item, menu or menu item. A `run_actions` with any other step, or with a step that is not `press`, is refused whole, so a sequence never stops halfway because the lock blocks a later step.

While locked, the header of a read lists the app's windows from the window server, numbered as `screenshot` and `click_at` take them, and adds `screen=locked`:

```text
app="CUA Fixture" windows=[0:"Fixture Other" 1:"Fixture Main"] screen=locked
```

Menu commands that act on the current document (Save, Duplicate) are disabled while the app has no key window, locked or not; see [What works in the background](../README.md#what-works-in-the-background).

### Window requests

Everything else that needs a window's elements stops with `screen_locked`: there are no elements to read, and acting on an element number read before the lock would act on something the agent can no longer see or check. An element number from before the lock is not used for anything but menu items.

## Windows while locked

An optional mode, off by default, on the Setup tab of the Backstage window under Background. With it on, an agent can work on windows while the screen is locked the way a person works from a picture of the screen: take a screenshot, click by position, press keys and type into whatever has focus.

### How it works

| Request | Route while locked |
|---|---|
| `screenshot` | The window is picked from the window server's list of the app's ordinary windows (layer 0) that were on screen when the screen locked, front to back, by the `window` index. `SLSHWCaptureWindowList` captures it at full resolution, and the helper scales the image to one pixel per window point, so its coordinates work with `click_at`, as unlocked |
| `click_at` with `x`, `y` | The point is checked against the window's bounds from the window server, then a click is posted to the app's process addressed to that window number and point, the same background route as when unlocked |
| `press_key` | Key events posted to the app's process; they reach whatever element has focus |
| `type_text` without `element` | Each character as key events to the app's process; line breaks and tabs are refused, as when unlocked |

For Chromium and Electron apps `click_at` first makes the target window key inside the app, as when unlocked, because they take input only in their key window; keys then go to that window, so click before typing. Nothing activates the app, moves the cursor or touches the lock screen.

The sequence measured on the fixture through the MCP server:

```text
screenshot app=CUA Fixture window=1           → 420×452 PNG of "Fixture Main", "presses: 1"
click_at   app=CUA Fixture window=1 x=52 y=55 → pointer_event, verified: false; the fixture logged a press
click_at   app=CUA Fixture window=1 x=200 y=112 → the text field took focus
type_text  app=CUA Fixture text="locked hi"   → key_events, verified: false; the field logged "locked hi"
screenshot app=CUA Fixture window=1           → the counter shows "presses: 2"
```

### Why it is built this way

Unlocked, Backstage prefers accessibility: it reads elements, acts on them by number, and confirms each action by reading the window again. While locked, accessibility has nothing below the menu bar, so that route is gone. What remains is what the window server still does: list windows, draw them and route events to them. The mode uses exactly that and nothing more:

- **The window server list instead of accessibility** to find windows, because it is the one source that still knows their numbers, titles and bounds.
- **`SLSHWCaptureWindowList` instead of ScreenCaptureKit**, because ScreenCaptureKit has no display to capture from while locked. The SkyLight call captures a window by number without a display. It is private, so it is looked up at run time; on a macOS without it, `screenshot` fails with `action_failed` instead of crashing.
- **The existing background input route**, already used unlocked for views without accessibility. It addresses events to the app's process and window, never to the system's event stream, so they cannot reach the lock screen or another app.
- **No mixing with element requests.** Element numbers are refused while locked except for menu items, so an agent cannot act on a stale reading of a window it cannot see.

### What it gives

- An agent can finish window work that ready operations do not cover, such as a form in an app without scripting, while the user is away and the Mac stays locked.
- The Mac stays locked and the displays stay asleep: measured after screenshots, clicks, keys and typing, with the system's idle time still counting.
- Nothing extra is needed from the user beyond the switch: Screen Recording, already used for unlocked screenshots, covers the capture.

### What it costs

- **No verification.** Every action replies `verified: false` and `state: { unknown: true }`. The only way to see an effect is another screenshot, and the agent has to compare the pictures itself. A click that misses, a dialog that opens or a field that rejects the text all look like success in the reply.
- **No elements.** The agent works from pixels and coordinates only: no labels, no values, no roles, no `set_value`, `select_text`, `scroll`, `drag` or `read_text`. Secure fields show their dots, as on screen.
- **Private API.** The capture call and the event routing rely on undocumented window server behavior. A macOS update can change or remove either, and Apple can decide that a locked screen should hide windows from them too.
- **It reaches past a protection macOS applies on purpose.** Apple stops Accessibility and ScreenCaptureKit while locked; this mode reads and operates windows anyway, through the window server. That is why it is off by default, why the switch says so, and why turning it on or off is recorded in the Activity tab. It does not weaken the lock against a person at the keyboard: nothing here shows on screen, unlocks the Mac or wakes it.
- **The user cannot watch.** Unlocked, a person at the Mac can see what an agent does and stop it. Locked, they cannot. Only allow it for apps and tasks you would leave an agent alone with.

### Limits

- **Only windows that were on screen when the screen locked.** A window that was minimized, hidden or on another Space is not in the list. Whether a window an app opens after the lock is listed is not measured.
- **No keyboard focus control.** Keys go to the element that has focus in the app. Click the target with `click_at` first, and check with a screenshot.
- **The window index can change.** It is the window server's front-to-back order. Read the header (`get_window_state` with `menu_bar: true`) or take a screenshot before each step.
- **Pointer-only actions only.** `click_at` with `element` is refused, because element frames are not available; so is `foreground: true`, which would need to bring a window forward on a locked screen.
- **Same app list.** The mode applies to the apps agents may use and nothing else. Passwords, Keychain Access, other password managers, authenticators and wallets, login and authentication windows and Backstage itself stay unavailable.

### Turning it on and off

On the Setup tab, under Background, switch **Windows while locked**. The setting is stored as `worksInWindowsWhileLocked` in `~/.config/backstage/settings.json` and applies to the next request. The Activity tab records each change under Windows while locked, with On or Off, by You. Agents are told never to change Backstage's settings; like the app list, this relies on their cooperation (see [SECURITY.md](../SECURITY.md)).

## What Backstage does not do

- **Unlock the Mac.** Unlocking needs the user's password or Touch ID. Backstage does not keep, ask for or type either, and the server instructions tell agents never to try: a password an agent can type is a password it can leak.
- **Wake the displays.** Nothing allowed while locked posts to the system's event stream (which would reach the lock screen) or asserts user activity; `click_at` with `foreground: true`, the one tool that posts there, is refused while locked.
- **Wait for unlock.** A refused request returns at once. An agent that needs a window should tell the user or come back later. A queue that runs requests on unlock would act at a moment the user did not choose.

## Measuring it yourself

The live test (`make live`) runs unlocked. To repeat the locked measurements, start the fixture app (`Tests/Fixtures/target`, built as the live test builds it), start a script that waits until `CGSessionCopyCurrentDictionary()` reports `CGSSessionScreenIsLocked` and then calls the installed server over stdio, and lock the screen (Control-Command-Q). Read the fixture's log to see which events arrived; it records `press`, `raw_click`, `raw_key` and `text` events with `active: false` while the app stays in the background.

## Open questions

- An Apple event to TextEdit (`count documents`) timed out while locked when sent from a terminal, while Notes answered. A pending Automation prompt for the terminal, which cannot show while locked, would explain it; not checked yet.
- Whether apps whose windows were on another Space when the screen locked can be listed and captured.
