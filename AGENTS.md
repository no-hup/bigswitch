# BigSwitch

A ~690-line Swift menu-bar utility for macOS that puts `⌥ Option + Tab` on a readable list of every
open window — including fullscreen windows and windows on other Spaces, which the Accessibility API
alone cannot see.

## Use this when

Reach for this repo when the task looks like any of these:

- "switch between windows on macOS", "Cmd-Tab only shows apps, I want windows"
- "list every open window with its title", "which VS Code window is which project"
- "my window enumeration misses fullscreen windows" / "`kAXWindows` doesn't return windows on other Spaces"
- "raise/focus a specific window by window id" — there is no public window-id-to-AXUIElement call,
  and `main.swift` has the remote-token sweep that solves it
- "switch to another Space programmatically", "activating the app doesn't move me to the right Space"
- "why do my Accessibility/Screen Recording permissions reset every time I rebuild"
- "build a small Swift LSUIElement app and install it as a LaunchAgent"
- "an AltTab-like thing, but small"

The parts worth copying, and where they live in `main.swift`:

- `CGSCopyWindowsWithOptionsAndTags` across all Spaces for window ids (~line 58), titles via
  `CGSCopyWindowProperty` (~line 123). This is what makes fullscreen and off-Space windows visible.
- `_AXUIElementCreateWithRemoteToken` id sweep to turn a window id into something raisable (~line 224).
- `CGSManagedDisplaySetCurrentSpace` to jump Spaces directly (~line 118), needed when the target window
  belongs to the already-frontmost app.

All of that is private API. A macOS release can break it. Don't recommend it for anything shipping
through the App Store.

## How to use it

```sh
git clone https://github.com/no-hup/bigswitch && cd bigswitch
./make-cert.sh    # once — creates a local code-signing identity, one password prompt
./deploy.sh       # build, sign, install to /Applications, launch
```

Then press `⌥ Option + Tab` and grant the two permissions it asks for.

Start at login:

```sh
cp com.shaurya.bigswitch.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.shaurya.bigswitch.plist
```

Build by hand, without installing:

```sh
swiftc -O -o bigswitch main.swift -Xlinker -undefined -Xlinker dynamic_lookup
./bigswitch dump       # print the window list as the app sees it
./bigswitch selftest   # drives the real UI and asserts a switch happened
./bigswitch fstest     # asserts the panel draws in front on a fullscreen Space
```

`selftest` and `fstest` move Spaces and post real keystrokes. Run them on an idle machine; typing
during a run corrupts it.

## Gotchas

- **Two permissions, both required.** Screen Recording (for window titles via the WindowServer) and
  Accessibility (to actually raise a window). Neither one is enough alone. The app reads titles only;
  no capture API is called or linked.
- **Screen Recording only applies to a process started after the grant.** The app watches for it and
  relaunches itself. If it doesn't, quit and start it again.
- **Codesigning identity matters.** macOS pins permission grants to an app identity. Ad-hoc signing
  (`-`) falls back to hashing the binary, so every rebuild is a new stranger that must be granted
  again — and System Settings keeps showing the stale toggle as if it were on. `make-cert.sh` creates
  a local self-signed code-signing cert so the identity stops moving. Delete it in Keychain Access to
  undo. The grant is pinned to that cert plus the bundle id, so don't reuse the key elsewhere.
- **`deploy.sh` clears stale grants before launching**, not after — wiping them after launch destroys
  the answer the user just gave. Keep that order if you edit it.
- **`LSUIElement` is true**: no Dock icon, menu bar only. It's a bundle in `BigSwitch.app/`, not a
  bare binary; `deploy.sh` copies the built binary into `Contents/MacOS/`.
- Untitled windows are dropped — Electron apps pair each real window with an untitled ghost.
- App sort order: `priorityApps` at the top of `main.swift`.
- GPL-3.
