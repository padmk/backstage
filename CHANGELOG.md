# Changelog

## Unreleased

The first version: Backstage operates Mac apps for MCP clients in the background.

- A signed helper app operates apps through Accessibility, ScreenCaptureKit and background event posting that reaches windows behind others through private window server calls, looked up at run time with a fallback to the public ones. The `backstage` command inside it serves MCP over stdio (revisions 2024-11-05 to 2025-11-25 with initialize, 2026-07-28 without), installs the app (`setup`), checks the Mac (`doctor`) and edits the app list (`approvals`).
- Twenty-three tools: `list_apps`, `launch_app`, `list_operations`, `run_operation`, `get_window_state`, `read_text`, `screenshot`, `press`, `set_value`, `type_text`, `select_text`, `press_key`, `scroll`, `drag`, `click_at`, `list_windows`, `set_window`, `set_app_state`, `close`, `list_menu_commands`, `run_menu_command`, `wait_for` and `run_actions`. Nothing brings an app forward or moves the cursor, except `click_at` with `foreground: true` as a last resort, which gives the focus back.
- Every action reports how it was delivered, whether it was verified and what changed once the app settled. A second read of the same place returns only what changed. Requests for one app run one at a time across agents, and actions are refused while the user works in that app.
- Ready operations for Notes, Reminders, Calendar, Contacts, Mail, Messages, Music, Finder, Pages, Numbers, Shortcuts and System Settings, through each app's scripting, EventKit or the Contacts framework. Each reads its result back, never replaces a file and starts a closed app hidden.
- Agents may use only the apps on the user's list, or every app when the user allows that; nothing asks during a task. Entries are bound to the app's signer. Passwords, Keychain Access, login and permission windows and Backstage itself are never available. macOS grants for operations are asked for when the user adds an app, never during a task.
- The Backstage window: Apps, Setup and Activity tabs, Open at login and a menu bar item. The activity log keeps its newest thousand records once it passes 200 KB.
- While the screen is locked, ready operations and the menu bar keep working and window requests stop with `screen_locked`; Windows while locked, off by default, adds screenshots and input by position, unverified.
- `setup` signs the installed app with a certificate of this Mac, so permissions survive updates without a paid developer account, and swaps it in atomically; nothing else replaces it. A command from another build than the installed app refuses instead of stopping the helper. Files live at the XDG defaults.
- Shortcuts `run` reports `verified: false`, since a shortcut's effect cannot be read back; turning on Windows while locked asks for confirmation.
- An update through `setup` opens nothing; only the first install opens the window.
- A cancel never reaches the app before the request it names, and a request to the app never waits past its deadline, however slowly the app reads.
- Windows as objects: `list_windows` across apps and displays, `set_window` for frames and layouts (halves, quarters, thirds, maximize, center, on any display), minimizing and full screen, `set_app_state` to hide and show, and `close` for windows and quitting, each read back.
- Every app's menu commands: `list_menu_commands` with paths, shortcuts and enabled states, and `run_menu_command` by path or shortcut, without opening a menu. `wait_for` waits for text to show or go.
- Items in the Apple, Services and Share menus are refused on every route. Adding an app over the socket waits for the user in the Backstage window. The socket bounds request size, queued requests, connections and sessions, and no longer asks for Screen Recording. Listings leave out paths outside the reachable set. Apps signed with a certificate of their own stay on the list across updates.
- `backstage uninstall`, installing into `~/Applications` for accounts that cannot write to `/Applications`, private call availability in `doctor`, and a Homebrew formula for the tap. The bundle id is `app.foreverbeta.backstage`.
