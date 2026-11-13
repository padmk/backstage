# Changelog

## Unreleased

- `user_active` also covers an app in the background: scrolling, dragging or clicking over its window in the last 2 s refuses an action there. Scrolling now counts at all; macOS keeps no time for it in the state Backstage read. A click with `foreground: true` no longer counts as the user's own input.
- `run_actions` checks the app list, the app, the screen lock and `user_active` again before each step after the first, and reports the steps that ran when it stops.
- A click where Accessibility cannot tell what lies under the point is refused while the app shows a menu, since the item there cannot be checked against the Apple, Services and Share menus. So is a click where Accessibility gives only the window. A click on a part of such an item, such as its image, is checked as the item.
- Messages reads contact names only while Contacts is on the app list, not only while macOS allows it, so removing Contacts from the list stops it.
- `launch_app` looks at `files` only for an app on the list, so a refusal no longer depends on whether a path exists.

## 0.2.3

- Every tool takes `computer`, the name `ssh` reaches another of the user's Macs under, and runs there through that Mac's installed Backstage, with its own app list and checks. One SSH connection per Mac stays open for the session, so element numbers keep their meaning; a Mac that cannot be reached, or has no Backstage, answers `computer_unreachable`. No entry per Mac is needed in the MCP client.
- Messages: the names `list_chats` and `read_chat` take from Contacts are found again; Contacts refused the lookup by phone number and email address without asking for those keys.

## 0.2.2

- A press or menu command the app answers with AX error -25200 no longer fails at once: apps built with SwiftUI answer so when a press opens or closes a sheet, though it worked. The reply carries `app_error`, `verified: false` and `state`, and is `action_failed` only when nothing changed; in `run_actions` the step stops the steps as `outcome_unknown`.
- The MCP instructions and [Tools](docs/tools.md) tell agents to close the menus, popovers and palettes they open, which show on the user's screen above their work.

## 0.2.1

- Messages: `list_chats` and `read_chat` find a person's chats by the name the Messages sidebar shows, taken from Contacts once Contacts is allowed on the Setup tab, and label chats and senders with it (`contact_names`, `from_name`). Without Contacts, a search that finds nothing says so. Backstage never asks for Contacts during a task.
- `--render-window <folder>` draws the window's tabs into PNG files at 2x for the documentation's pictures, without showing a window.

## 0.2.0

The first release: Backstage lets AI agents use Mac apps in the background, through any MCP client.

- **An MCP server and a signed helper app.** The `backstage` command inside the app serves MCP over stdio (revisions 2024-11-05 to 2025-11-25 with `initialize`, 2026-07-28 without) and forwards each call to the helper, which holds the macOS permissions and the app list. It works through Accessibility, ScreenCaptureKit, background event posting that reaches windows behind others through private window server calls (looked up at run time, with a fallback to the public ones), Apple events, EventKit, Contacts, PhotoKit and a Core Audio tap.
- **24 tools:** `list_apps`, `launch_app` (also handing an app files to open), `list_operations`, `run_operation`, `get_window_state`, `read_text`, `screenshot` (with the text recognized in it on this Mac, for views without elements), `press`, `set_value`, `type_text`, `select_text`, `press_key`, `scroll`, `drag`, `click_at`, `run_actions` (up to 20 steps in one call), `list_windows`, `set_window`, `set_app_state`, `close`, `list_menu_commands`, `run_menu_command`, `wait_for` and `record_audio`. Nothing brings an app forward or moves the cursor, except `click_at` with `foreground: true` as a last resort, which gives the focus back ([Tools](docs/tools.md)).
- **Every action says what changed.** Each reply reports how the action was delivered, whether it was verified and what changed once the app settled; a second read of the same place returns only what changed. Requests for one app run one at a time across agents, and actions are refused with `user_active` while the user types, clicks, or moves the pointer over that app's windows.
- **Ready operations** for Notes, Reminders, Calendar, Contacts, Mail (drafts, never sending), Messages (sending, and reading chats and attachments from its history), WhatsApp (chats, messages and media from its data on the Mac), Photos (finding and copying out), Music, Finder, Pages, Numbers, Shortcuts and System Settings. Each reads its result back, starts a closed app hidden and never replaces a file. Home, Bear, Telegram, Discord and Chromium browsers get hints and pitfalls for their windows ([App knowledge](docs/app-knowledge.md)).
- **Windows and menus as objects.** `list_windows` across apps, displays and Spaces; `set_window` for frames and layouts (halves, quarters, thirds, maximize, center, on any display), minimizing and full screen; hiding and showing apps; closing windows and quitting apps, each read back. `list_menu_commands` and `run_menu_command` find and run any app's menu commands by path or shortcut without opening a menu.
- **A list of apps the user controls.** Agents may use only the apps on the list, or every app when the user allows that; nothing asks during a task. Entries are bound to the app's signer, and an app asked for over the socket waits for the user in the window. Passwords, Keychain Access, other makers' password managers, authenticators and wallets, the system's login and permission prompts, Backstage itself, the items of the Apple, Services and Share menus and a toolbar's Share button are never available. macOS grants for operations are asked for when the user adds an app, never during a task.
- **The Backstage window:** Apps, Setup and Activity tabs, requests waiting for the user above them, Open at login and a menu bar item. Screen Recording and System Audio Recording are optional and asked for only when the user presses Allow; Full Disk Access, for WhatsApp and the Messages history, comes with a panel to drag Backstage into System Settings ([The Backstage window](docs/window.md)).
- **A locked screen.** Ready operations and the menu bar keep working and window requests stop with `screen_locked`; Windows while locked, off by default, adds screenshots and input by position, unverified ([Locked screen](docs/locked-screen.md)).
- **Install, updates and removal.** `brew install padmk/tap/backstage` or `make install`, then `backstage setup`, which signs the installed app with a certificate of this Mac so permissions survive updates without a paid developer account, and swaps it in atomically, into `/Applications` or `~/Applications`. Running sessions move to a new build on their next request. `backstage doctor` checks the Mac, `backstage approvals` lists, asks for and removes apps, `backstage uninstall` removes the app, and `backstage version` prints the version ([Install](docs/install.md)).
