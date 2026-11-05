# Backstage

Backstage lets any MCP client operate Mac apps in the background. An agent reads a window as numbered elements, acts on them, and is told what changed, while you keep working in another app. For well-known apps it carries ready operations that skip the window entirely. You choose which apps agents may use.

It is one Swift package: a signed helper app that does the work through Accessibility, background event posting, ScreenCaptureKit, Apple events, EventKit and the Contacts framework, and the `backstage` command inside it, which serves MCP over stdio and sets the app up.

## Install

Needs a Mac with Apple silicon and the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/padmk/backstage
cd backstage
make install
```

`make install` builds `build/Backstage.app` and runs its `setup`: it installs the app into `/Applications`, signed with a certificate of this Mac so macOS keeps its permissions across updates, waits for you to enable it under **Accessibility**, registers `/Applications/Backstage.app/Contents/Helpers/backstage mcp` as the `backstage` MCP server with Claude Code and Codex, and opens the Backstage window on the Apps tab. Screen Recording is optional, for screenshots.

## Tools

| Tool | What it does |
|---|---|
| `list_apps`, `launch_app` | Lists running apps with whether agents may use each; starts one in the background |
| `list_operations`, `run_operation` | Ready operations for well-known apps |
| `get_window_state` | Reads a window, the menu bar or a subtree as numbered elements; a second read of the same place returns only what changed |
| `read_text`, `screenshot` | A long value in full; a window as a PNG |
| `press`, `set_value`, `type_text`, `select_text` | Act on an element by its number |
| `press_key`, `scroll`, `drag`, `click_at` | Keys, scrolling, drags and clicks at a point in a window |
| `run_actions` | Several actions in one app as one request |

No tool brings an app forward or moves the cursor, except `click_at` with `foreground: true` as a last resort. Every action reply says how it was delivered and what changed once the app settled.

## App operations

Notes, Reminders, Calendar, Contacts, Mail, Messages, Music, Finder, Pages, Numbers, Shortcuts and System Settings have operations that use the app's own automation (scripting, EventKit, Contacts) and read their result back. `list_operations` lists them with their arguments.

## Which apps agents may use

Agents may use an app only when it is on your list, on the Apps tab of the Backstage window, or when Allow every app is on there. Nothing asks during a task: an app that is not allowed is refused at once with `not_approved`. List entries are bound to the app's signer. Passwords, Keychain Access, login windows and Backstage itself are never available.

```sh
backstage approvals add Notes
backstage approvals list
backstage approvals revoke com.apple.Notes
```

## Development

```sh
make app      # build/Backstage.app
swift test    # The command against a fake helper, and the app built for tests
make live     # The installed app operates a test app in the background
```

## License

MIT
