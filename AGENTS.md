# Working on Backstage

Backstage is one Swift package: the helper app (`Sources/App`), the `backstage` command that serves MCP and sets the app up (`Sources/Tool`), and what they share (`Sources/HelperLink`). The module map is in [README.md](README.md#development); the design and its reasons are in [docs/architecture.md](docs/architecture.md).

## Commands

```sh
make app        # build/Backstage.app: release build, bundle assembly, ad hoc signature (Command Line Tools are enough)
make install    # make app, then its setup: install into /Applications signed for this Mac, Accessibility, MCP registration
swift test      # Protocol tests against a fake helper and app tests against a bare build with --home; needs Xcode
make live       # LIVE=1: the installed app operates the fixture app in the background; needs Accessibility and the fixture on the list
make bench      # BENCH=1: latency against the installed app
```

CI (macOS) runs `make app`, type-checks the fixture app and runs `swift test`. macOS runners are expensive, so push finished work in batches.

## Constraints

- Never move the pointer, activate a window or bring an app forward while testing, unless the user agrees. Use background reads, the fixture's log (`Tests/Fixtures/target`), screenshots and logs instead. A first `setup` opens the Backstage window at its end (an update does not), so say so before running it on a Mac without the app.
- Clients run the command inside the installed app. Changes in the checkout reach them only after `make install`; running sessions then move to the new command on their next request (see Builds and updates in docs/architecture.md), and changing how that handoff works needs a new `Product.sessionHandoffRevision`.
- The command never uses Accessibility or other grants itself: it starts the app through LaunchServices (`open -g -j`) and talks to it over the socket, so macOS attributes the grants to the app.
- Builds are told apart by the linker's UUID of the app executable (`Sources/HelperLink/BuildIdentity.swift`), which signing does not change. A command from another build than the installed app must hand its session over or refuse, never stop a helper others use.
- Keep the bundle id `app.foreverbeta.backstage` (`Product.bundleIdentifier`): macOS ties every user's permissions and settings to it, so a change costs them all a regrant. The live test's fixture is `app.foreverbeta.backstage.fixture`, signed with the local Backstage certificate so the app list keeps it; the first live run asks the user to add it in the window.
- Only a bare build outside a bundle honors `--home`; any copy of the bundle uses the user's real files.
- Private macOS calls are looked up at run time with `lookUp` in `Sources/App/BackgroundEvents.swift` and must degrade to a public call or a clear error when missing.
- Every ready operation reads its result back and reports `verified`; nothing retries a change by itself. See [docs/app-knowledge.md](docs/app-knowledge.md).
- Every action on an element passes `requireAllowedMenu` (`Sources/App/MenuSafety.swift`); new routes that act on elements must too. Adding to the app list over the socket only queues a request (`Sources/App/ApprovalRequests.swift`); only the window adds.
- Behavior on a locked screen is decided in `Sources/App/Presence.swift` and `Sources/App/LockedWindows.swift`; keep [docs/locked-screen.md](docs/locked-screen.md) in step with them.
- Update README, SECURITY, PRIVACY and the docs with any change to what agents or users get.
