# BigSwitch

A window switcher for macOS that shows **every open window as a big, readable list** — including
windows on other Spaces and fullscreen windows, which Mission Control shows as unlabelled thumbnails
and which `Cmd-Tab` does not show at all.

Press `⌥ Option + Tab`:

```
1  ⧉  empty                         Code · Claude code thinking visualisation
2  ⧉  benefills-emergent            Code · Benefits.com migration tracker
3  ⧉  plattr-pro                    Code · Codebase and tech stack review
4  ◉  Best coding tool for AI subs  Google Chrome
5  ◐  dating-assist                 Code · Plan ads launch · minimized
```

Built because with ten windows open — mostly VS Code and Chrome — Mission Control's tiles are too
small to tell apart, and it never shows window titles.

## Why it exists

Mission Control scales its tiles to fit however many windows you have, and there is no setting to
make them bigger. With ten windows you get ten tiny screenshots and no text. BigSwitch shows the
title instead, which is the thing you actually navigate by.

For editors it promotes the **project name** to the headline: VS Code titles look like
`some file — my-project`, and `my-project` is what you are looking for.

## Install

```sh
git clone https://github.com/no-hup/bigswitch
cd bigswitch
./make-cert.sh     # one-time: local signing identity (see "Permissions" below)
./deploy.sh        # build, install to /Applications, start
```

Then press `⌥ Option + Tab` and grant the two permissions it asks for.

To start it at login:

```sh
cp com.shaurya.bigswitch.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.shaurya.bigswitch.plist
```

## Keys

| Key | Action |
|---|---|
| `⌥ Option + Tab` | open; press again to move down the list |
| `↑` `↓` | move selection |
| `1`–`9` | jump straight to that window |
| `Return` / click | switch to selected window |
| `Esc` / click away | close |

## Permissions, and why each is genuinely required

BigSwitch needs **two** permissions. Both are load-bearing; this was measured, not assumed.

| Permission | Used for | Why nothing else works |
|---|---|---|
| **Screen Recording** | reading window **titles** | The Accessibility API only lists windows on the *current* Space. Measured on a real setup: it reported **5 of VS Code's 9 windows** — every fullscreen window was invisible to it. Only the WindowServer sees them all, and reading any window title through it is gated behind this permission. |
| **Accessibility** | **raising** the chosen window | The WindowServer can see windows but cannot bring one forward. Verified failing five different ways, including from an active app. |

**BigSwitch does not record or capture anything.** "Screen Recording" is macOS's name for one
permission covering two abilities: reading window titles, and reading window pixels. This program
only does the first — a single string per window, read when you press the shortcut. You can check:

```sh
grep -rE 'CGWindowListCreateImage|CGDisplayCreateImage|SCStream|CGDisplayStream' main.swift
nm -u /Applications/BigSwitch.app/Contents/MacOS/BigSwitch | grep -iE 'capture|CGImage|SCStream'
```

Both come back empty. The capture APIs are not called and are not linked into the binary.

### Why `make-cert.sh` exists

macOS remembers a permission grant against an app's *identity*. An ad-hoc-signed app has none, so
macOS falls back to a hash of the binary — and **every rebuild then looks like a brand-new app that
must be re-granted**, while System Settings still shows the old entry switched on, granting nothing.

`make-cert.sh` creates a local self-signed code-signing certificate in your login keychain, so the
app's identity becomes "this bundle id, signed by this certificate" — stable across rebuilds. It
asks for your password once (changing keychain trust settings requires it) and never again.

The certificate can do nothing but sign code. To remove it: Keychain Access → delete
"BigSwitch Local Signing".

## How it works

Three problems, three mechanisms:

1. **Finding every window.** `CGSCopyWindowsWithOptionsAndTags` over every Space returns all window
   ids including fullscreen and minimized ones; titles come from `CGSCopyWindowProperty`. Windows
   with empty titles are skipped — Electron apps pair each real window with an untitled ghost.

2. **Getting a handle to raise.** `kAXWindows` omits other-Space windows entirely. For those, an
   element is forged from a *remote token* (pid + magic + element id) and element ids are walked
   until one reports the window id we want — typically found within a few dozen ids, in ~20ms.
   Bounded by a time budget.

3. **Actually switching.** Activating an app is the usual way to reach another Space, but it does
   nothing when the target belongs to the app that is **already frontmost** — switching between two
   fullscreen VS Code windows, the main case here. So the Space change is requested directly via
   `CGSManagedDisplaySetCurrentSpace`, then the window is raised.

These are private, undocumented APIs. They can break in a future macOS release.

## Development

```sh
./deploy.sh              # build, install, restart
./bigswitch dump         # print the window list as the app sees it
./bigswitch selftest     # drive the real UI end-to-end and assert it works
```

`selftest` opens the panel, checks it did not drag you to another Space, checks repeat presses
advance the selection, then switches to an off-Space window and asserts the Space actually changed.
Run it after any change.

Configure which apps sort first via `priorityApps` at the top of `main.swift`.

## Credits

The two hardest mechanisms were learned by reading [AltTab](https://github.com/lwouis/alt-tab-macos)
(GPL-3), whose source documents the remote-token sweep and the synthetic-event byte layout — the
latter tracing back to [yabai](https://github.com/koekeishiya/yabai) and
[Hammerspoon](https://github.com/Hammerspoon/hammerspoon). If you want a mature, thumbnail-capable
switcher with settings and support, use AltTab. BigSwitch is a deliberately small alternative: a
list, a shortcut, no thumbnails.

Licensed GPL-3, matching AltTab.
