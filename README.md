# BigSwitch

Ten windows open. Mission Control gives you ten grey rectangles the size of postage stamps.
Cmd-Tab gives you apps, not windows. Neither one tells you which VS Code window is which project.

BigSwitch is `⌥ Option + Tab`, and a list you can actually read.

```
┌──────────────────────────────────────────────────────────────┐
│  1  ⧉  empty                    Code · Claude code thinking  │
│  2  ⧉  benefills-emergent       Code · Benefits.com migrat…  │
│  3  ⧉  plattr-pro               Code · Codebase review       │
│  4  ◉  Best coding tool for AI  Google Chrome                │
│  5  ◐  dating-assist            Code · Plan ads · minimized  │
└──────────────────────────────────────────────────────────────┘
```

Project name first, because that's what you're actually looking for. VS Code titles read
`some file — my-project`, so the part after the dash gets promoted and the rest goes grey.

Fullscreen windows show up. Windows on other Spaces show up. Minimized ones sit at the bottom.

## Install

```sh
git clone https://github.com/no-hup/bigswitch && cd bigswitch
./make-cert.sh    # once. see "the certificate" below
./deploy.sh       # build, install, run
```

Hit `⌥ Option + Tab`, grant the two permissions it asks for, done.

Start it at login:

```sh
cp com.shaurya.bigswitch.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.shaurya.bigswitch.plist
```

## Keys

| | |
|---|---|
| `⌥ Option + Tab` | open. press again to walk down |
| `1`–`9` | jump straight there |
| `↑ ↓` then `Return` | or click |
| `Esc` | close |

## The two permissions

Neither is optional, and I checked rather than guessed.

**Accessibility** can't see your fullscreen windows. On a real setup it reported 5 of VS Code's
9 windows. The 4 fullscreen ones were invisible. So it can't build the list.

**The WindowServer** sees all 9 with titles, but can't bring one forward. Verified failing five
different ways, including from an active app.

So: WindowServer finds them, Accessibility raises them. That's why AltTab asks for both too.

### It does not record your screen

"Screen Recording" is one macOS permission covering two abilities: reading window *titles* and
reading window *pixels*. This reads titles. One string per window, when you press the shortcut.

Don't take my word for it:

```sh
grep -rE 'CGWindowListCreateImage|CGDisplayCreateImage|SCStream' main.swift
nm -u /Applications/BigSwitch.app/Contents/MacOS/BigSwitch | grep -iE 'capture|CGImage'
```

Both empty. The capture APIs aren't called and aren't linked in.

### The certificate

macOS pins a permission grant to an app's identity. Ad-hoc signed apps don't have one, so it falls
back to hashing the binary, and every rebuild becomes a stranger that has to be granted again. The
worst part: System Settings keeps showing the old toggle switched on while it grants nothing.

`make-cert.sh` makes a local self-signed certificate so the identity stops moving. Password once,
never again. It can do nothing except sign code. Delete it from Keychain Access to undo.

The flip side, stated plainly: the permission grant is pinned to *that certificate plus the bundle id*,
so anything else signed with the same key and bundle id would inherit the grant. The key lives in your
login keychain, so this only matters to something already running as you. Same trade-off every signed
app on your Mac makes; just don't reuse the key for anything else.

Screen Recording takes effect only for a process started after it was granted. BigSwitch watches for
the grant and relaunches itself, so you shouldn't have to think about it. If it somehow doesn't, quit it
and start it again.

## How it works

Three problems. The obvious fix failed on all three.

**Finding windows.** `kAXWindows` skips anything on another Space, so window ids come from
`CGSCopyWindowsWithOptionsAndTags` across every Space, titles from `CGSCopyWindowProperty`. Empty
titles get dropped, since Electron apps pair every real window with an untitled ghost.

**Getting something to raise.** There's no window-id-to-AX-element call. So you forge an element
from a remote token (pid, magic number, element id) and walk ids until one reports the window id you
wanted. Usually a few dozen ids, about 20ms. Time-boxed so it can't hang.

**Switching.** Activating an app usually carries you to its Space, but does nothing when the target
belongs to the app that's already frontmost, which is exactly the case when you're moving between
two fullscreen VS Code windows. So ask for the Space directly with
`CGSManagedDisplaySetCurrentSpace`, then raise.

All private API. A macOS update could break any of it.

## Hacking on it

```sh
./deploy.sh          # build, install, restart
./bigswitch dump     # the window list as the app sees it
./bigswitch selftest # drives the real UI, asserts it actually switched
./bigswitch fstest   # asserts the panel draws in FRONT on a fullscreen Space
```

Run these on an idle machine. They move Spaces and post real keystrokes, so touching the
keyboard mid-run corrupts the result.

`selftest` opens the panel, checks it didn't yank you to another Space, checks repeat presses walk
the list, then switches to an off-Space window and confirms the Space changed. Run it after changes.

Which apps sort first: `priorityApps` at the top of `main.swift`.

## Not AltTab

[AltTab](https://github.com/lwouis/alt-tab-macos) is the mature one. Thumbnails, settings, years of
edge cases handled. Use it.

I read its source to learn two things I couldn't have worked out alone: the remote-token sweep, and
the synthetic-event byte layout (which it got from [yabai](https://github.com/koekeishiya/yabai) and
[Hammerspoon](https://github.com/Hammerspoon/hammerspoon)). BigSwitch is the small version. A list,
a shortcut, no thumbnails, under 600 lines.

GPL-3, same as AltTab.
