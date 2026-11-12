# Installing and running Backstage

This page covers what Backstage needs, what `setup` does, updates and signing, uninstalling, the command line, where files live and what to do when something does not work.

## Requirements

- A Mac with Apple silicon and macOS 26 or newer (the two latest versions). The app goes into `/Applications`, or into `~/Applications` for an account that cannot write there.
- The Xcode command line tools (`xcode-select --install`) to build it. Xcode itself is needed only for the tests.
- An MCP client: setup registers with Claude Code and Codex, and prints the configuration for any other.

## Setup

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

Homebrew builds the app from the release's source with `make app`, keeps it in its own prefix and puts the `backstage` command on your `PATH`. It never writes outside its prefix or asks for a permission, so its notes after `brew install` and every `brew upgrade backstage` ask you to run `backstage setup`; after an upgrade, agents keep the previous version until you do. `make install` builds `build/Backstage.app` with Swift Package Manager and runs its setup. Either way, `setup`:

1. Installs the app into `/Applications` (or `~/Applications`), signed with a certificate of this Mac (see [Signing and updates](#signing-and-updates)). An app already installed in either place is updated where it is.
2. Opens System Settings and waits up to 3 minutes for you to enable Backstage under **Accessibility**, the one permission it needs. If it is not listed, drag it there from the Finder window setup opens.
3. Registers `/Applications/Backstage.app/Contents/Helpers/backstage mcp` as the `backstage` MCP server with Claude Code (at user scope) and Codex, when they are installed, and prints the configuration for other clients. Sessions started after setup see the tools.
4. On the first install, opens the Backstage window on the Apps tab, where you choose the apps agents may use. An update opens nothing.

| Command | Effect |
|---|---|
| `make app` | Build `build/Backstage.app` only, signed ad hoc |
| `build/Backstage.app/Contents/Helpers/backstage setup --no-register` | Install without registering with Claude Code or Codex |

For any other MCP client, use the stdio server setup prints:

```json
{
  "args" : [
    "mcp"
  ],
  "command" : "/Applications/Backstage.app/Contents/Helpers/backstage"
}
```

### Optional permissions

**Screen Recording** and **System Audio Recording** are optional. Only `screenshot` (and `get_window_state` with `screenshot: true`) uses Screen Recording, for web pages and apps that show no elements; only `record_audio` uses System Audio Recording, to record what an allowed app plays, such as a voice message that cannot be downloaded. You do not need to set them up in advance: the first time an agent needs one, the Backstage window opens with an Allow button for it under Waiting for you. Allow either at any time on the Setup tab.

Ready operations need the macOS grants of their apps (Automation, Reminders, Calendars, Contacts, Photos). macOS asks for them once, when you add the app on the Apps tab. WhatsApp's operations and reading the Messages history need Full Disk Access, which macOS never asks for: the Setup tab opens its pane with a panel to drag Backstage into the list. See [The Backstage window](window.md).

### The command

The `backstage` command lives inside the app, at `/Applications/Backstage.app/Contents/Helpers/backstage`; MCP clients run it with `mcp`. Homebrew links its own copy onto your `PATH`. From a checkout, link the installed one to use it by name, for example `ln -s /Applications/Backstage.app/Contents/Helpers/backstage ~/.local/bin/backstage`.

| Command | What it does |
|---|---|
| `backstage setup [--no-register]` | Install or update the app, ask for Accessibility, register with Claude Code and Codex |
| `backstage doctor` | Check this Mac (see [Troubleshooting](#troubleshooting)) |
| `backstage approvals [list]` | List the apps agents may use, with their signers |
| `backstage approvals add <app>` | Ask for an app by name or bundle id; it goes on the list when you click Add in the window |
| `backstage approvals revoke <bundle-id>` | Remove an app from the list, at once |
| `backstage uninstall [--reset]` | Remove the app, its login item and its MCP registrations; `--reset` also its data |
| `backstage mcp` | Serve MCP over stdio (MCP clients run this) |
| `backstage version` | Print the version |

```sh
backstage approvals add Notes          # asks you in the Backstage window; added once you click Add
backstage approvals list
backstage approvals revoke com.apple.Notes
```

`approvals add` only asks: the command cannot tell you from an agent running it, so the app goes on the list when you add it in the window. Removing an app takes effect with the next request of every session.

## Signing and updates

macOS ties permissions to the app's signature. The first setup creates a certificate of this Mac in a keychain of its own and signs the installed app with it, so the permissions survive updates without a paid Apple developer account, as long as the certificate stays. Any process running as you can use that certificate; [SECURITY.md](../SECURITY.md#signing) explains what that means.

To update, run `brew upgrade backstage` (or pull and `make install`), then `backstage setup`. Setup copies the new bundle next to the installed one, signs the copy and swaps the two in one step, so the registered path never disappears. Running client sessions move to the new version on their next request, without a restart; element numbers from before then need a new read. Nothing changes the installed app but an explicit setup. How the handoff works is in [Builds and updates](architecture.md#builds-and-updates).

## Uninstall

`backstage uninstall` quits the app, turns off its login item and menu bar item, removes its MCP registrations from Claude Code and Codex and moves the app to the Trash; the app list, settings and certificate stay for a later install. `backstage uninstall --reset` removes those too, after you type `yes`, and resets the app's macOS permissions and the defaults macOS keeps for it. With Homebrew, run it before `brew uninstall backstage`, which does not touch the copy in Applications.

## Files

Backstage keeps its files at the XDG defaults, in `0700` directories. The `XDG_*` variables are not read, because the app also starts from launchd, at login or from the Finder, without the shell's environment.

| Path | Holds |
|---|---|
| `/Applications/Backstage.app` (or `~/Applications`) | The app, and the command in `Contents/Helpers/backstage` |
| `~/.config/backstage/approvals.json` | The app list (`0600`) |
| `~/.config/backstage/settings.json` | The window's switches (Allow every app, Windows while locked, the menu bar item), the last tab, and which apps' data macOS has been asked about (`0600`) |
| `~/.local/share/backstage/` | The signing keychain `signing.keychain-db`, the certificate's hash in `signing.identity`, and the setup lock |
| `~/.local/state/backstage/` | The socket `helper.sock`, the start lock and the activity log `decisions.jsonl` (`0600`) |

Copies an agent asked for and recordings live in private folders in the system's temporary folder; [PRIVACY.md](../PRIVACY.md#what-stays-on-disk) lists them. Outside these places, macOS keeps what it owns: the permissions, the login item (Open at login) and the app's defaults.

## Troubleshooting

`backstage doctor` checks macOS, the installed app and its signature, Accessibility, Screen Recording, System Audio Recording, the grants of the listed apps and the private macOS calls background delivery uses. It exits with 1 when a required check fails; optional ones are marked `--`.

| Symptom | Fix |
|---|---|
| A permission shows as enabled but `doctor` says missing | Remove the entry with `-` in Settings, then run `backstage setup` |
| `setup` opens no prompt | macOS asks once per service. Enable the app in the pane `setup` opens |
| `not_approved` | The app is not on the list. Add it on the Apps tab, or turn on Allow every app |
| `stale_element` or `unknown_element` | Read the window again |
| `screen_locked` | Unlock the Mac, or let the agent use ready operations and the menu bar; see [Working while the screen is locked](locked-screen.md) |
| `Backstage is not installed. Run: backstage setup` | The command had to start the app, but none is installed in Applications, as with Homebrew's copy before the first `backstage setup` or after `backstage uninstall`: run `backstage setup` |
| `This backstage command belongs to another build` | The session runs a command from another build that could not hand its session to the installed one (a build that declares another handoff revision): restart the session |
| The tools do not show in a client after the first setup | Start a new session: clients load MCP servers when a session starts |
