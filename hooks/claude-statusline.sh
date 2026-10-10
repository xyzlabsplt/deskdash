#!/bin/sh
# claude-statusline.sh: Claude Code's status line command, which also tells deskdash how much of the plan's
# 5-hour and weekly limits is used.
#
# Claude Code runs it from ~/.claude/settings.json (scripts/install-claude-statusline.sh adds the entry):
#     "statusLine": { "type": "command", "command": "/path/to/deskdash/hooks/claude-statusline.sh" }
# On a Pro or Max plan the JSON on stdin carries rate_limits.five_hour and rate_limits.seven_day, each
# { used_percentage, resets_at }, from the session's first reply on. This copies that object, as it is, to
# ${DESKDASH_LIMITS_DIR:-~/.local/state/deskdash/limits}/claude.json, which the dashboard polls, and leaves the
# file alone when the JSON has none. Nothing else from the JSON is kept.
#
# It prints "5h 24% · 7d 82%" for the status bar. If you had a status line before, the installer saves its command
# as <limits dir>/statusline-next, and this hands that command the same JSON and prints its line instead.
# Needs jq (/usr/bin/jq ships with macOS 15 and later).

dir=${DESKDASH_LIMITS_DIR:-$HOME/.local/state/deskdash/limits}
jq=$(command -v jq || echo /usr/bin/jq)
input=$(cat)

limits=$(printf '%s' "$input" | "$jq" -c '.rate_limits // empty | select(type == "object" and length > 0)' 2>/dev/null)
if [ -n "$limits" ]; then
  mkdir -p "$dir" 2>/dev/null
  # Written whole and then renamed, so the dashboard never reads half a file.
  printf '%s' "$limits" | "$jq" -c --argjson now "$(date +%s)" '{updatedAt: ($now * 1000), rate_limits: .}' \
    > "$dir/claude.json.tmp" 2>/dev/null && mv -f "$dir/claude.json.tmp" "$dir/claude.json"
fi

next=$dir/statusline-next
if [ -x "$next" ]; then
  printf '%s' "$input" | "$next"
  exit 0
fi
[ -n "$limits" ] || exit 0
printf '%s' "$limits" | "$jq" -r '
  [ (.five_hour.used_percentage // empty | "5h \(floor)%"), (.seven_day.used_percentage // empty | "7d \(floor)%") ]
  | join(" · ")' 2>/dev/null
exit 0
