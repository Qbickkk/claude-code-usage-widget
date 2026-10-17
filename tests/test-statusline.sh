#!/bin/bash
# Tests statusline-usage.sh cache merging against a temporary HOME.
set -u
cd "$(dirname "$0")/.."
SCRIPT="$PWD/statusline-usage.sh"
export HOME=$(mktemp -d)
mkdir -p "$HOME/.claude"
CACHE="$HOME/.claude/usage-cache.json"
NOW=$(date +%s)
R5=$((NOW + 3600)); R7=$((NOW + 200000))
fail=0

feed() { echo "$1" | "$SCRIPT" >/dev/null; }
rl() { echo "{\"rate_limits\":{$1}}"; }
win() { echo "\"$1\":{\"used_percentage\":$2,\"resets_at\":$3}"; }
get() { /usr/bin/jq -r "$1" "$CACHE" 2>/dev/null; }
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$3', got '$2'"; fail=1; fi
}

feed "$(rl "$(win five_hour 20 $R5),$(win seven_day 30 $R7)")"
check "first write five" "$(get .five_hour.used_percentage)" 20
check "first write week" "$(get .seven_day.used_percentage)" 30

# Pretend the last write was long ago so a fresh write is visible in updated_at.
/usr/bin/jq '.updated_at = 1000' "$CACHE" >"$CACHE.t" && mv "$CACHE.t" "$CACHE"
feed "$(rl "$(win five_hour 15 $R5),$(win seven_day 28 $R7)")"
check "stale session keeps higher five" "$(get .five_hour.used_percentage)" 20
check "stale session keeps higher week" "$(get .seven_day.used_percentage)" 30
check "stale session does not bump updated_at" "$(get .updated_at)" 1000

feed "$(rl "$(win five_hour 25 $R5)")"
check "higher value in same window wins" "$(get .five_hour.used_percentage)" 25
check "absent window is kept" "$(get .seven_day.used_percentage)" 30
check "fresh data bumps updated_at" "$([ "$(get .updated_at)" -ge "$NOW" ] && echo yes)" yes

feed "$(rl "$(win five_hour 3 $((R5 + 18000)))")"
check "newer window wins even if lower" "$(get .five_hour.used_percentage)" 3

feed "$(rl "$(win five_hour 40 $R5)")"
check "older window from stale session ignored" "$(get .five_hour.used_percentage)" 3

before=$(cat "$CACHE")
feed '{"model":{"display_name":"Opus"}}'
check "no rate_limits leaves cache untouched" "$(cat "$CACHE")" "$before"
feed 'not json'
check "garbage leaves cache untouched" "$(cat "$CACHE")" "$before"
check "no temp files left" "$(ls -A "$HOME/.claude" | tr '\n' ' ')" "usage-cache.json "

rm -rf "$HOME"
exit $fail
