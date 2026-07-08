#!/bin/bash
# Shared iOS-simulator selection helper for the justfile recipes
# (ios-test, run-on-ipad-sim, run-on-iphone-sim).
#
# Usage: sim_select.sh <family> [name-fragment]
#   family        — device family grep, e.g. "iPhone" or "iPad"
#   name-fragment — optional fixed-string match on the simulator name,
#                   e.g. "iPhone 16 Pro"
#
# Selection: with a name fragment, the first available match wins; without
# one, prefer an already-booted simulator of that family, else the first
# available. The chosen simulator is booted (with a bootstatus wait) if it
# isn't already, and its UDID is printed on stdout — everything else goes
# to stderr so callers can capture the UDID with $(...).

set -euo pipefail

family="${1:?usage: sim_select.sh <family> [name-fragment]}"
name="${2:-}"

extract_udid() {
    sed -nE 's/.*\(([0-9A-F-]{36})\).*/\1/p' | head -n1
}

available="$(xcrun simctl list devices available)"

if [ -n "$name" ]; then
    udid="$(printf '%s\n' "$available" | grep "$family" | grep -F "$name" | extract_udid || true)"
else
    udid="$(printf '%s\n' "$available" | grep "$family" | grep 'Booted' | extract_udid || true)"
    if [ -z "$udid" ]; then
        udid="$(printf '%s\n' "$available" | grep "$family" | extract_udid || true)"
    fi
fi

if [ -z "$udid" ]; then
    echo "No available $family simulator found" >&2
    printf '%s\n' "$available" >&2
    exit 1
fi

if ! xcrun simctl list devices | grep "$udid" | grep -q 'Booted'; then
    xcrun simctl boot "$udid" >&2 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >&2
fi

printf '%s\n' "$udid"
