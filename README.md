# Backstage

Backstage lets any MCP client operate Mac apps in the background. An agent reads a window as numbered elements, acts on them, and is told what changed, while you keep working in another app. For well-known apps it carries ready operations that skip the window entirely.

It is one Swift package: a signed helper app that does the work through Accessibility, background event posting, ScreenCaptureKit, Apple events, EventKit and the Contacts framework, and the `backstage` command inside it, which serves MCP over stdio and sets the app up.

## Install

Needs a Mac with Apple silicon and the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/padmk/backstage
cd backstage
make install
```

`make install` builds `build/Backstage.app` and runs its `setup`: it installs the app into `/Applications`, signed with a certificate of this Mac so macOS keeps its permissions across updates, waits for you to enable it under **Accessibility**, and registers `/Applications/Backstage.app/Contents/Helpers/backstage mcp` as the `backstage` MCP server with Claude Code. Screen Recording is optional, for screenshots.

## Tools

| Tool | What it does |
|---|---|
| `list_apps`, `launch_app` | Lists running apps; starts one in the background |
| `list_operations`, `run_operation` | Ready operations for well-known apps |
| `get_window_state` | Reads a window or the menu bar as numbered elements |
| `screenshot` | Captures a window as a PNG |
| `press`, `set_value`, `type_text` | Act on an element by its number |
| `press_key`, `scroll`, `drag`, `click_at` | Keys, scrolling, drags and clicks at a point in a window |

No tool brings an app forward or moves the cursor, except `click_at` with `foreground: true` as a last resort. Every action reply says how it was delivered and whether the helper could confirm it.

## App operations

Notes, Reminders, Calendar, Contacts, Mail, Messages, Music, Finder, Pages, Numbers, Shortcuts and System Settings have operations that use the app's own automation (scripting, EventKit, Contacts) and read their result back. `list_operations` lists them with their arguments.

## Approvals

The first time an agent asks to use an app, Backstage shows a window that names the agent and the app, and you allow it or decline. Approvals are bound to the app's signer. Passwords, Keychain Access and login windows are never available. The Backstage window shows the macOS permissions, the approved apps and recent decisions.

## Development

```sh
make app      # build/Backstage.app
swift test    # The command against a fake helper
```

## License

MIT
