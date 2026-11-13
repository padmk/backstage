# Development

Backstage is one Swift package with three modules: the helper app (`Sources/App`), the `backstage` command that serves MCP and sets the app up (`Sources/Tool`), and what both share (`Sources/HelperLink`). The design and its reasons are in [architecture.md](architecture.md); agents changing the code start from [AGENTS.md](../AGENTS.md).

## Commands

```sh
make app       # build/Backstage.app: release build, bundle assembly, ad hoc signature (Command Line Tools are enough)
make install   # make app, then its setup: install into /Applications signed for this Mac, Accessibility, MCP registration
make test      # swift test
make tsan      # swift test under the thread sanitizer; fails on any report, also from the helper and command the tests start
make lint      # SwiftLint with .swiftlint.yml (brew install swiftlint)
make hooks     # lint the staged Swift files before each commit: puts a hook that runs .githooks/pre-commit in the repository's hooks folder, not core.hooksPath, so global hooks stay on
make check     # what CI runs: make lint, make app, then the tests
make live      # LIVE=1: the installed app operates the fixture app in the background
make bench     # BENCH=1: latency against the installed app
make clean     # remove build/ and .build/
```

`swift test` runs two test targets: `Tests/ToolTests`, the protocol tests against a fake helper and the app tests against a bare build of the app in a temporary home, and `Tests/AppTests`, which tests the app's pure functions through `@testable import App`. It needs Xcode, but no macOS permission. The live test and the benchmark need the app installed with Accessibility (`make install`) and the fixture app on the app list. The fixture is `Tests/Fixtures/target`, a small app named "Test Fixture" (bundle id `app.foreverbeta.backstage.fixture`) that logs what happened to it as JSON lines, so the live test checks the effect instead of the reply. It is signed with this Mac's Backstage certificate, so the list keeps it across builds; the first live run asks you to add it in the Backstage window. Benchmark results are in [bench/README.md](../bench/README.md).

Clients run the command inside the installed app, so changes in the checkout reach them only after `make install`. Running sessions then move to the new command on their next request ([Builds and updates](architecture.md#builds-and-updates)).

The window's pictures in `docs/images` are drawn offscreen at 2x, each tab at its whole height, with `--render-window <folder>`, which writes `window-apps.png`, `window-setup.png` and `window-activity.png` there. Run it from a bare build with a sample home, so the pictures show a sample list and activity rather than yours: put an `approvals.json` and a `decisions.jsonl` in a temporary folder, then run `swift build` and `"$(swift build --show-bin-path)/Backstage" --home <that folder> --render-window <output folder>`. The grants shown are those of the process that runs it. It shows no window and changes nothing, so it also runs while the installed helper serves agents.

`backstage version` prints `Product.version` from `Sources/HelperLink/Product.swift`, which `make app` also writes into the bundle's `Info.plist`; the Homebrew formula's test checks it.

`SWIFT_BUILD_FLAGS` passes extra flags to every `swift build` the Makefile runs; the formula passes `--disable-sandbox`, because SwiftPM's own sandbox cannot start inside Homebrew's build sandbox.

## Checks

Every target, the tests included, builds in the Swift 6 language mode, so the compiler checks for data races, and any warning fails the build. `ALLOW_WARNINGS=1` (`make app ALLOW_WARNINGS=1`, or in the environment of `swift build`) keeps warnings warnings; the Homebrew formula passes it, so warnings a newer Xcode adds never stop an install.

Shared mutable state follows these rules, which the compiler holds the code to:

- State behind a lock lives in one `Mutex<State>` (`Synchronization`) holding all of it, so a check and the change it allows happen in one `withLock`.
- A framework object that is not `Sendable`, such as a contact or event store, is reached only through `Exclusive` (`Sources/App/Common.swift`), and nothing of it is kept past the closure.
- `@unchecked Sendable` and `nonisolated(unsafe)` appear only with a comment that says what guards the value. JSON handed to another thread goes in `SharedJSON` (`Sources/HelperLink/SharedJSON.swift`), which checks in debug builds that it holds only JSON values.
- AppKit code is `@MainActor`; work from another thread reaches it through `onMain` or `DispatchQueue.main`.

SwiftLint (`.swiftlint.yml`) enables only `force_cast`, `file_length` and `function_body_length` (800 and 200 lines), and `try_without_reason`: a `try?` says in a comment on its line or the line above why dropping the error is right. Casts to Core Foundation types go through `cfCast` in `Sources/App/Accessibility.swift`, which compares type ids first and is the one force cast. CI and the pre-commit hook run `swiftlint lint --strict`.

The app writes failures no request hears about, such as a write to the activity log or the settings that did not happen, to the unified log through `appLog`: `log show --last 1h --predicate 'subsystem == "app.foreverbeta.backstage"'`.

## Environment variables

| Variable | Read by | Effect |
|---|---|---|
| `HELPER_TEST_HOME` | `backstage mcp`, `backstage approvals`, `backstage uninstall` | Use this folder for the socket, the app list, the settings and the log instead of the XDG directories; `uninstall` then removes nothing. Tests only; a bare app build is started with `--home` to match |
| `HELPER_NO_START` | `backstage mcp`, `backstage approvals` | Never start the helper; fail when nothing listens on the socket. Tests only |
| `HELPER_TEST_INSTALLED_APP` | the command, only with `HELPER_TEST_HOME` | The bundle the command treats as the installed app, for tests of builds and handoffs |
| `HELPER_TEST_SSH` | the command, only with `HELPER_TEST_HOME` | The program run in place of `/usr/bin/ssh` for `computer`, for tests of calls to another Mac |
| `HELPER_TEST_TIMEOUT` | the command, only with `HELPER_TEST_HOME` | Seconds the command waits for a reply from the helper instead of 200 |
| `LIVE` | the live test | `LIVE=1` runs `LiveTests` (what `make live` sets) |
| `LIVE_COMMAND` | the live test | The command the live test runs; default the test build's `backstage-tool` |
| `BENCH` | the benchmark | `BENCH=1` runs `BenchTests` (what `make bench` sets) |
| `BENCH_ROUNDS` | the benchmark | Rounds per measure, default 30 |

Only a bare build outside a bundle honors `--home`; any copy of the app bundle uses the user's real files.

## CI

CI (`.github/workflows/ci.yml`) runs on `macos-26` on every push to `main` and every pull request, and cancels a run that a newer push to the same branch supersedes. One job prints the Swift version, lints with SwiftLint's release (checked against its published digest), builds and assembles the app (`make app`, failing on any warning in its log, since the release build reports some concurrency warnings that `-warnings-as-errors` leaves as warnings), type-checks the fixture app and runs `swift test`; a second runs the tests under the thread sanitizer, with the reports of the helper and the command the tests start written to files, and fails on any report. The live test needs real permissions, so it runs only locally. Dependabot proposes updates of the pinned GitHub Actions once a month.

## Releasing

1. Set `Product.version` in `Sources/HelperLink/Product.swift`.
2. Head the release's section of `CHANGELOG.md` with `## <version>`, exactly; its text becomes the release notes.
3. Have GPT-6.1 Sol at `xhigh` review the whole difference since the previous `v<version>` tag, given only the code and the project's rules, not earlier findings; confirm each finding in the code and fix the confirmed ones first. Reviews of single changes miss what lies between them.
4. Push `main` and wait until CI passes for that commit.
5. Push the tag `v<version>` on that commit.

The tag starts `.github/workflows/release.yml`. It builds the app and runs the tests on `macos-26`, checks the signature and that `backstage version` matches the tag, renders the formula, and takes the CHANGELOG section as notes; a tag without a matching version or section stops there, as does one while the `release` environment (open to `v*` tags only) has no `HOMEBREW_TAP_TOKEN`, a fine-grained token that may write to the tap's contents. It then requires the tag to point at a commit of `main` whose CI run passed, waiting up to 30 minutes for one still running, and creates the GitHub release. Last, it renders `packaging/homebrew/backstage.rb.tmpl` with the version and the checksum of the tag's source archive into the tap (`<owner>/homebrew-tap`) as `Formula/backstage.rb`. Running the workflow by hand is a dry run that builds and checks without publishing.

## Code map

| Path | Responsibility |
|---|---|
| `Package.swift`, `Makefile`, `packaging/Info.plist` | The Swift package, and assembling and installing the app bundle |
| `.swiftlint.yml`, `.githooks/pre-commit` | The lint rules ([Checks](#checks)) and the hook that runs them on each commit |
| `packaging/homebrew/backstage.rb.tmpl` | The template of the formula, rendered into the tap at each release |
| `.github/workflows/ci.yml`, `release.yml` | CI, and the release from a `v<version>` tag ([Releasing](#releasing)) |
| `.github/ISSUE_TEMPLATE/`, `.github/dependabot.yml` | The bug report form and the pointer to private vulnerability reports; updates of the pinned actions |
| `assets/` | The app icon |
| `Sources/HelperLink/Product.swift` | The product's name, version, bundle id, install locations, handoff revision and directories; the steps `run_actions` takes |
| `Sources/HelperLink/BuildIdentity.swift`, `Framing.swift` | The build identity (the linker's UUID); line-delimited JSON for the socket and stdio |
| `Sources/HelperLink/PipeReader.swift`, `SharedJSON.swift` | Reading a child's output to its end; JSON handed to another thread |
| `Sources/HelperLink/ComputerName.swift` | Which names `computer` takes, checked by the command and the app alike |
| `Sources/Tool/ToolMain.swift`, `Commands.swift` | The command's entry; `setup`, `doctor`, `approvals`, `uninstall`, `version` |
| `Sources/Tool/Install.swift` | Installing and signing the app for this Mac |
| `Sources/Tool/MCPServer.swift`, `Tools.swift` | MCP over stdio, the tool definitions and their argument checks |
| `Sources/Tool/HelperClient.swift` | Starting the app and talking to it over its socket, with the build check |
| `Sources/Tool/Handoff.swift` | Handing a running MCP session to the installed command after an update |
| `Sources/Tool/RemoteComputers.swift` | Calls with `computer`: one SSH connection per Mac to its `backstage mcp` |
| `Sources/Tool/Processes.swift` | Running other programs; naming the command and its app in messages |
| `Sources/App/HelperMain.swift`, `Server.swift` | The app's start, the Unix socket, connections and sessions |
| `Sources/App/Requests.swift` | The request router |
| `Sources/App/Common.swift` | Types and small helpers the app's modules share |
| `Sources/App/Approvals.swift`, `ApprovalRequests.swift` | The app list and the check every request passes; apps asked for over the socket, waiting for the user |
| `Sources/App/Computers.swift` | The other Macs agents may reach with `computer`, and those asked for, waiting for the user |
| `Sources/App/SystemPermissions.swift` | Screen Recording and System Audio Recording, asked for only from the window |
| `Sources/App/Apps.swift` | Finding apps, starting them in the background and handing them files |
| `Sources/App/Accessibility.swift`, `Tree.swift` | Reading apps and numbering elements; rendering windows as lines |
| `Sources/App/Actions.swift`, `TextSelection.swift` | Acting on windows; reading and selecting text by what it says |
| `Sources/App/Observation.swift`, `Sequences.swift` | Change reports after actions, the per-app lock, and `run_actions` |
| `Sources/App/Input.swift`, `BackgroundEvents.swift`, `Capture.swift` | Key and pointer events, background delivery through private calls, screenshots |
| `Sources/App/Presence.swift`, `PointerActivity.swift`, `LockedWindows.swift` | The user working in the target app, from the system's input times and the app each click, scroll and drag went to; the locked screen and Windows while locked |
| `Sources/App/WindowManagement.swift` | `list_windows`, `set_window`, `set_app_state`, `close`: displays, frames, layouts |
| `Sources/App/TextRecognition.swift` | The text recognized in a screenshot with Vision, in reading order |
| `Sources/App/MenuCommands.swift`, `MenuSafety.swift` | Menu commands with their shortcuts; the Apple, Services and Share menus refused, with the points and keys checked against them |
| `Sources/App/WaitFor.swift` | `wait_for` |
| `Sources/App/AudioRecording.swift` | `record_audio`: a muted Core Audio tap of an app and its helper processes |
| `Sources/App/MenuBar.swift`, `LaunchAtLogin.swift`, `Preferences.swift` | The menu bar item, starting at login, and the settings in `settings.json` |
| `Sources/App/window/`, `Theme.swift` | The Backstage window: one file per tab, the waiting section, the drag panel for Full Disk Access, its model, texts and look, and drawing the tabs into the pictures of the documentation (`WindowRendering.swift`) |
| `Sources/App/apps/Catalog.swift` | The catalog of app knowledge, `list_operations` and `run_operation` |
| `Sources/App/apps/AppAccess.swift` | The macOS grants ready operations need, as the Setup tab shows them |
| `Sources/App/apps/Scripting.swift`, `EventStore.swift`, `ReadOnlyDatabase.swift`, `Typedstream.swift`, `UserPaths.swift` | The routes operations share: the `osascript` runner, EventKit, read-only SQLite, the reader for Messages' archived text, and the rule for which files operations may touch |
| `Sources/App/apps/` (the other files) | One file per app: Notes, Reminders, Calendar (`CalendarApp.swift`), Contacts, Mail, Messages and its history (`MessagesHistory.swift`), Music, Finder, Pages and Numbers (`IWork.swift`), Shortcuts, System Settings (`Settings.swift`), WhatsApp, Photos, Home, and the hint-only apps (`HintsOnly.swift`) |
| `Tests/ToolTests/` | Protocol tests against a fake helper (`ServerTests`), app tests against a bare build (`HelperTests`), the app list as socket clients meet it (`AppListTests`), calls to another Mac through a stand-in for ssh (`RemoteComputerTests`), the live test and the benchmark |
| `Tests/AppTests/` | The app's pure functions through `@testable import App`: ready operations' paths, values, scripts and databases, the app list's rules, menu safety and key combinations, change reports, recording and window rules, and text recognition (`TextRecognitionTests`) |
| `Tests/Fixtures/target/` | The fixture app the live test and the benchmark operate |
