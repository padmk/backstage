# How Backstage works, and why

This page explains the parts of Backstage, what happens to a request, and the reasoning behind the main choices. For what each tool does, see the [README](../README.md); for the security model, [SECURITY.md](../SECURITY.md).

## The parts

```text
MCP client (Claude Code, Codex, ...)
   │  JSON-RPC over stdio
   ▼
backstage mcp  (Backstage.app/Contents/Helpers/backstage, Sources/Tool)
   │  checks arguments, forwards requests, one socket connection and one session per server
   ▼  Unix socket ~/.local/state/backstage/helper.sock
Backstage.app  (the helper app, Sources/App, started through LaunchServices)
   │  holds the macOS permissions and the app list, decides every request
   ▼
Accessibility · window server events · ScreenCaptureKit · Apple events · EventKit · Contacts · shortcuts
```

- **The command** (`backstage`, inside the app bundle) serves MCP over stdio when a client runs it with `mcp`: it validates arguments against the tool schemas, starts the helper when needed and forwards each call over the socket. It keeps nothing about the user. Its instructions to clients put the access policy first, because clients cut long server instructions. The same command installs the app (`setup`), checks this Mac (`doctor`) and edits the list (`approvals`). It uses Foundation only, never AppKit or a privacy-protected API.
- **The helper** is a signed macOS app in `/Applications`. It holds Accessibility, the optional Screen Recording, and the Automation, Reminders, Calendars and Contacts grants. It also holds the app list and checks every request against it, so a process that talks to the socket directly meets the same rules as an agent. It shows the Backstage window, and stops 2 minutes after the last client disconnects unless Open at login or the menu bar item is on.
- **HelperLink** is the code both share: the product's name, version and bundle id, the directories, line framing and the build identity.

**Why two processes.** macOS attributes privacy permissions to the process responsible for a request. A program an MCP client starts directly runs on the client's behalf, so its Accessibility would be the terminal's or the client's, and would change with whatever runs it. The helper is started through LaunchServices (`open -g -j`), so macOS treats it as its own app: its grants stay stable across updates, in one place the user can see and revoke. The command only forwards requests and needs no grant.

**Why one Swift package.** The app and the command share their code and their version, build with the Command Line Tools alone, and ship as one bundle. The command starts in about 20 ms with under 10 MB of memory, which matters because every client session starts one.

**Builds and updates.** Clients run the command inside the installed app, which only an explicit `setup` replaces: it copies the bundle next to the installed one, signs the copy for this Mac and swaps the two in one step (`renamex_np` with `RENAME_SWAP`), so the registered path never disappears. Each process reads its build identity once, at start: the linker's UUID of the app executable, which follows the code and not the signature. When the running helper is another build, the command restarts it only if the installed app is the command's own build; if the command itself is the older one, it refuses and asks for a new session, so a session that started before an update never stops the helper that newer sessions use.

## A request, step by step

1. The client calls a tool. The server checks the arguments and sends the request over the socket with a ticket, so the request can be cancelled later.
2. The helper resolves the app by name or bundle id and checks it against the list (`ApprovalGate`). It checks that the process is still the one resolved, since a pid can be reused.
3. It checks the screen lock (see [Locked screen](locked-screen.md)) and takes the app's lock. Requests for one app run one at a time across all sessions, so two agents never interleave their clicks and keys in one app. Other apps go on in parallel.
4. Holding the lock, it checks the list, the process and the screen lock again, because the user may have changed something while the request waited. For an action, it refuses with `user_active` if the app is in front and the user used the keyboard or mouse in the last 2 seconds.
5. It runs the request: a read, an action, a screenshot or a ready operation.
6. For an action, it reads the same place again until the app has stayed the same for 0.3 seconds (up to 5 seconds, longer while a new busy indicator shows), and replies with what changed.

A cancelled request stops between steps, between typed characters, or by stopping its script or shortcut child. When something may already have changed, the reply is `outcome_unknown`, never a plain failure the agent might retry.

## Reading windows

`get_window_state` walks the accessibility tree from a window, a menu bar or a subtree and renders one line per element: a number, the role, the labels, the value and the actions it offers. One batched attribute call per element keeps it fast (about 16 ms for 25 elements; see [bench/README.md](../bench/README.md)).

- **Element numbers** belong to one session and one app. Each number keeps a fingerprint of what the element was (role, labels, and the value of text, cells and rows). A number whose element has since become something else is refused as `stale_element`, so an agent never presses a different button than the one it read.
- **Change reports.** Reading the same place again returns only the lines that were added or removed since the last read or action there; `full: true` returns all of it. Values longer than 300 characters show their start, their length and a digest, so a change anywhere shows as a changed line; `read_text` returns the rest.
- **Loops in the tree.** An element that lists itself or an ancestor among its children is shown once.
- **Electron apps** build their tree only when asked; the helper sets `AXManualAccessibility` once per process. **Chromium web content** has no tree, so agents use `screenshot` and `click_at` there.

## Acting in the background

The goal is that the user can keep working in another app while an agent works. No tool brings an app forward, except `click_at` with `foreground: true` as a last resort, which gives the focus back afterwards.

| Action | Route |
|---|---|
| `set_value`, `select_text`, `type_text` with an element | Accessibility: an action or an attribute set on the element, which needs no focus |
| `click_at`, `drag`, clicks on elements without an action | Pointer events posted to the app's process and addressed to its window and a point in it, through private window server calls, so the real cursor does not move |
| `press_key`, `type_text` without an element | Key events posted to the app's process, which reach its focused element |
| `scroll` | Accessibility: the value of the nearest scroll bar around the element |
| `press` | Accessibility: the element's press action |

Chromium and Electron apps take pointer and key input only in their key window. Before input to one that is not active, the helper makes the target window key inside the app with window server records, without activating or raising it. This is not done for AppKit apps: on the fixture it made the app report itself active.

An app can still bring itself forward, for example when it shows a dialog. The helper records the front app before each action and gives it the focus back, reporting `focus_returned`.

**Why private calls.** The public `CGEventPostToPid` routes a click by what is under the real cursor, so it cannot click a window behind another one. The private SkyLight calls `SLEventPostToPid` and `CGEventSetWindowLocation` let an event name its window and the point in it, and `SLPSPostEventRecordTo` makes a Chromium window key inside its app. Each is looked up at run time; when one is missing, the helper falls back to the public call instead of crashing, and the behavior degrades rather than breaks. The full list is in `Sources/App/BackgroundEvents.swift` and `Sources/App/LockedWindows.swift`; `status` and `backstage doctor` report which of them this macOS has.

## Windows and menus

**Windows.** `list_windows` takes the windows from the window server, which knows every app's windows on every display and Space, and adds what Accessibility knows for the apps on the user's list: title, minimized, full screen, modal, movable and resizable. Accessibility makes every change (`set_window`, `close`), since it is the public way to move another app's window, and reads the frame back: an app may clamp a window to its minimum size, so the reply says `adjusted` rather than claiming the frame asked for. Accessibility reaches only the current Space, so a window elsewhere is listed but not changed, and nothing moves windows between Spaces (that needs private calls macOS has closed to other processes). Bringing a window back from the Dock and full screen put it in front, so they need `foreground: true`. A window id is the window server's number, checked against the app that owns it before any change.

**Menus as commands.** Almost everything an app can do is in its menus, with its keyboard shortcut, and Accessibility exposes the whole menu bar without opening a menu. `list_menu_commands` turns that into a list an agent can search, and `run_menu_command` presses one item by its path or shortcut. This is per-app knowledge that needs no upkeep: it works in apps nobody described and follows an app's own updates. Its limits are AppKit's: items an app fills only while a menu is open can be missing, and commands on the current document are disabled while the app has no key window in the background. Items in the Apple menu (Restart, Log Out) and the Services and Share menus are refused on every route, since they act on the whole Mac or hand content to other apps past the list.

## Verifying what happened

An action reply says how it was delivered and what the helper saw afterwards:

- `delivery`: `accessibility`, `value_appended_at_end`, `key_events`, `pointer_event` or `foreground_pointer_event`.
- `verified`: `true` only when the helper observed the result (a value read back, a change in the tree). `false` means it was sent but not confirmed.
- `state`: the change in the area last read, or `unknown` with the reason.

**Why report instead of assume.** An agent that believes an action worked when it did not goes on to act on a state that does not exist, and the mistakes compound. An agent told "sent, not confirmed" takes a screenshot or reads again. So every reply states what was observed, and nothing retries by itself: a retried click, message or event creates a duplicate.

## Ready operations

For well-known apps the helper carries typed operations that use the app's own automation surface: JavaScript for Automation scripts run as `osascript` children of the helper, EventKit, the Contacts framework, `shortcuts`, and System Settings URLs. They are faster than the window, work while the app is hidden, closed or the screen is locked, and read their result back. Design, scope and measurements are in [app-knowledge.md](app-knowledge.md).

**Why compiled operations, not a script tool.** Scripts are fixed in the helper and arguments travel as data, never as script text, so an approval of Notes gives agents the Notes operations and nothing else. An open AppleScript tool behind the same gate would turn one approval into control of every scriptable app.

**Why two tools, not one per operation.** Every tool schema goes to the model in every conversation. Dozens of operation tools would cost context whether a task touches those apps or not. `list_operations` and `run_operation` keep the tool list short, and the agent loads one app's operations when it needs them.

**Why no prompts during a task.** A macOS permission prompt is a dialog that comes to the front and waits. In an unattended session it would block until a timeout. So prompts appear only when the user adds an app or presses Allow on the Setup tab; during a task, a missing grant fails at once with `permission_missing`.

## The app list

Agents may use an app only when the user put it on the list, or turned on Allow every app. Nothing asks during a task: an app not on the list is refused with `not_approved`.

**Why a list and not prompts.** Prompts during a task block unattended sessions, train people to click Allow, and show up on whatever screen the user is looking at. A list decided in advance works the same at 3 a.m. as at noon. The cost is setup: the user adds apps once.

Adding an app over the socket, from the command line or by an agent, only asks: the request waits on the Apps tab until the user adds it, because the socket cannot tell an agent from the user running the same command. Removing an app narrows access and takes effect at once. List entries are bound to the app's signer (its team, or its certificate when it has none), never-available apps (Passwords, Keychain Access, login and authentication windows, Backstage itself) are refused whatever the settings, and the server instructions ask agents to respect the list by every route. The limits of that are in [SECURITY.md](../SECURITY.md).

## Signing and permissions

`setup` signs the installed app, the command inside it first, with a self-signed certificate kept in a keychain of its own in `~/.local/share/backstage`. macOS ties permissions to the signature's designated requirement (the bundle id and that certificate), so an update signed with the same certificate keeps every grant; an ad hoc signature would lose them on every build. This needs no paid Apple developer account; it also gives no Developer ID trust or notarization, so the app is built on the Mac it runs on. The trade-off, that a process running as the user can sign code as Backstage, is in [SECURITY.md](../SECURITY.md#signing).

## Files

| Path | Holds |
|---|---|
| `/Applications/Backstage.app` (or `~/Applications`) | The helper app, and the command in `Contents/Helpers/backstage` |
| `~/.config/backstage/approvals.json` | The app list (`0600`) |
| `~/.local/share/backstage/` | The signing keychain and its certificate hash |
| `~/.local/state/backstage/` | The socket, the start lock and the activity log `decisions.jsonl` |
| `~/Library/Preferences/app.foreverbeta.backstage.plist` | The window's switches: Allow every app, Windows while locked, Open at login and the menu bar item |

The directories are `0700`. The `XDG_*` variables are not read, because the helper also starts from launchd, at login or from the Finder, without the shell's environment, and must find the same files. The bundle id, `app.foreverbeta.backstage`, stays fixed: macOS ties the permissions to it, so changing it would ask every user to grant everything again.
