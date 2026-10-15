#!/bin/bash
# Runs ON the Mac mini (fed over ssh stdin): kill the named Android emulators and shut
# down the named iOS Simulators, so a finished gate leaves nothing of its own up.
# Other agents share the mini: only the named devices are touched.
#   ssh <mini> 'bash -s -- hollow-a hollow-b' < scripts/mini_devices_down.sh
# Every command reads /dev/null: adb and simctl would otherwise eat the rest of this
# script from stdin.
adb=~/Library/Android/sdk/platform-tools/adb
for serial in $("$adb" devices < /dev/null 2> /dev/null | awk '/^emulator-/{print $1}'); do
    avd=$("$adb" -s "$serial" emu avd name < /dev/null 2> /dev/null | head -1 | tr -d '\r')
    for name in "$@"; do
        [ "$avd" = "$name" ] && "$adb" -s "$serial" emu kill < /dev/null > /dev/null 2>&1
    done
done
for name in "$@"; do
    udid=$(xcrun simctl list devices < /dev/null | grep -F "$name (" | grep -oE '[0-9A-F-]{36}' | head -1)
    [ -n "$udid" ] && xcrun simctl shutdown "$udid" < /dev/null > /dev/null 2>&1
done
exit 0
