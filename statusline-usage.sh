#!/bin/bash
# Claude Code statusline: prints plan usage and caches rate_limits for the menu bar app.
# Claude Code passes session JSON on stdin; rate_limits is present for Pro/Max after the first API response.

JQ=/usr/bin/jq
CACHE="$HOME/.claude/usage-cache.json"
input=$(cat)
now=$(date +%s)

if echo "$input" | $JQ -e '.rate_limits | type == "object"' >/dev/null 2>&1; then
  old=$($JQ -c . "$CACHE" 2>/dev/null || echo '{}')
  tmp="$CACHE.$$"
  # Several sessions write here, and an idle one reports its last, older numbers.
  # Usage only grows inside a window, so for the same window the larger value is the fresher one;
  # a later resets_at (by more than a minute) means a newer window.
  if echo "$input" | $JQ --argjson old "$old" --argjson now "$now" '
    def merge($o; $n):
      if $o == null or $o.used_percentage == null then $n
      elif $n == null or $n.used_percentage == null then $o
      elif ($n.resets_at // 0) > ($o.resets_at // 0) + 60 then $n
      elif ($o.resets_at // 0) > ($n.resets_at // 0) + 60 then $o
      elif $n.used_percentage >= $o.used_percentage then $n
      else $o end;
    .rate_limits as $r
    | { five_hour: merge($old.five_hour; $r.five_hour),
        seven_day: merge($old.seven_day; $r.seven_day) }
    | . + { updated_at: (
        if ([.five_hour == ($r.five_hour // .five_hour), .seven_day == ($r.seven_day // .seven_day)] | all)
        then $now else $old.updated_at end) }
  ' >"$tmp"; then
    mv -f "$tmp" "$CACHE"
  else
    rm -f "$tmp"
  fi
fi

echo "$input" | $JQ -r --argjson now "$now" '
  def color(p): if p >= 90 then "\u001b[31m" elif p >= 75 then "\u001b[33m" else "\u001b[32m" end;
  def win($name; $w; $fmt):
    if $w == null or $w.used_percentage == null then empty
    elif ($w.resets_at // 0) > 0 and $w.resets_at <= $now then "\($name) 0%"
    else "\(color($w.used_percentage))\($name) \($w.used_percentage | floor)%\u001b[0m"
      + (if $w.resets_at then " ↻" + ($w.resets_at | strflocaltime($fmt)) else "" end)
    end;
  [ (.model.display_name // empty),
    (if .context_window.used_percentage then "ctx \(.context_window.used_percentage | floor)%" else empty end),
    win("5h"; .rate_limits.five_hour; "%H:%M"),
    win("7d"; .rate_limits.seven_day; "%a %H:%M")
  ] | join(" · ")
' 2>/dev/null
