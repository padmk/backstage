# Backstage

Backstage lets any MCP client operate Mac apps in the background. An agent reads a window as numbered elements, acts on them, and is told what changed, while you keep working in another app.

It is one Swift package: a signed helper app that does the work through Accessibility and background event posting, and the `backstage` command inside it, which serves MCP over stdio and sets the app up.

## Install

Needs a Mac with Apple silicon and the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/padmk/backstage
cd backstage
make install
```

`make install` builds `build/Backstage.app` and runs its `setup`: it installs the app into `/Applications`, signed with a certificate of this Mac so macOS keeps its permissions across updates, waits for you to enable it under **Accessibility**, and registers `/Applications/Backstage.app/Contents/Helpers/backstage mcp` as the `backstage` MCP server with Claude Code.

## Tools

| Tool | What it does |
|---|---|
| `list_apps` | Lists running apps |
| `launch_app` | Starts an app by name or bundle id |
| `get_window_state` | Reads a window as numbered elements |
| `screenshot` | Captures a window as a PNG |
| `press`, `set_value`, `type_text` | Act on an element by its number |
| `press_key`, `scroll`, `click_at` | Keys, scrolling and clicks at a point in a window |

Every action reply says how it was delivered and whether the helper could confirm it.

## Approvals

The first time an agent asks to use an app, Backstage shows a window that names the agent and the app, and you allow it once, for a while, or always, or decline. Approvals are bound to the app's signer. Passwords, Keychain Access and login windows are never available.

## Development

```sh
make app      # build/Backstage.app
swift test    # The command against a fake helper
```

## License

MIT
