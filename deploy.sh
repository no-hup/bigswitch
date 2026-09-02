#!/bin/bash
# Build + install BigSwitch. Order matters: clear stale permission grants BEFORE launching, so the app's
# request is the one that reaches the user (doing it after launch wipes the answer they just gave).
set -e
cd "$(dirname "$0")"

before=$(codesign -d --verbose=4 /Applications/BigSwitch.app 2>&1 | awk -F= '/^CDHash/{print $2}')

swiftc -O -o bigswitch main.swift -Xlinker -undefined -Xlinker dynamic_lookup
./bigswitch dump >/dev/null || { echo "✗ dump failed — not shipping"; exit 1; }

mkdir -p BigSwitch.app/Contents/MacOS
cp bigswitch BigSwitch.app/Contents/MacOS/BigSwitch
if security find-identity -v -p codesigning 2>/dev/null | grep -q "BigSwitch Local Signing"; then
    SIGN="BigSwitch Local Signing"   # stable identity: TCC keys on the CERT, so rebuilds keep their grants
else
    SIGN="-"                          # ad-hoc: TCC keys on the content hash, rebuilds lose their grants
fi
codesign --force --deep --sign "$SIGN" BigSwitch.app 2>/dev/null
after=$(codesign -d --verbose=4 BigSwitch.app 2>&1 | awk -F= '/^CDHash/{print $2}')

PLIST=~/Library/LaunchAgents/com.shaurya.bigswitch.plist
launchctl unload "$PLIST" 2>/dev/null || true
pkill -x BigSwitch 2>/dev/null || true        # -x: exact process name. -f would also kill an editor with the path open
sleep 1
# copy first, swap second: a failed copy must not leave the user with no app at all
rm -rf /Applications/BigSwitch.app.new
cp -R BigSwitch.app /Applications/BigSwitch.app.new
rm -rf /Applications/BigSwitch.app
mv /Applications/BigSwitch.app.new /Applications/BigSwitch.app

if [ "$SIGN" != "-" ]; then
    echo "✓ signed with stable identity — permissions survive rebuilds, nothing reset"
elif [ "$before" != "$after" ]; then
    echo "⚠ fingerprint changed — macOS sees a new program, so old grants are stale."
    echo "    was: ${before:-<none>}"
    echo "    now: $after"
    tccutil reset ScreenCapture com.shaurya.bigswitch >/dev/null 2>&1 || true
    tccutil reset Accessibility com.shaurya.bigswitch >/dev/null 2>&1 || true
    echo "  cleared stale grants BEFORE launch, so the app will ask cleanly for both."
else
    echo "✓ fingerprint unchanged — permissions kept, no prompts"
fi

if [ -f "$PLIST" ]; then
    launchctl load "$PLIST"
else
    open -a /Applications/BigSwitch.app      # not a login item (fresh clone): just start it
fi
sleep 2
pgrep -x BigSwitch >/dev/null && echo "✓ running" || echo "✗ not running"
