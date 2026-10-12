#!/bin/sh
# Points Claude Code's status line (~/.claude/settings.json) at hooks/claude-statusline.sh, which passes the plan's
# usage limits to deskdash's limits page; --remove puts back what was there. Idempotent, and backs the file up first.
# A status line you already had keeps working: its command is saved as <limits dir>/statusline-next and runs after.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
cmd="$here/hooks/claude-statusline.sh"
file=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
dir=${DESKDASH_LIMITS_DIR:-$HOME/.local/state/deskdash/limits}
next=$dir/statusline-next
jq=$(command -v jq || echo /usr/bin/jq)

add=true
case ${1:-} in
  "") ;;
  --remove) add=false ;;
  *) echo "usage: $0 [--remove]" >&2; exit 2 ;;
esac

mkdir -p "$(dirname "$file")" "$dir"
current='{}'
if [ -f "$file" ]; then
  cp "$file" "$file.bak.$(date +%Y%m%d%H%M%S)"
  current=$(cat "$file")
fi
old=$(printf '%s' "$current" | "$jq" -r '.statusLine.command // ""')

if [ "$add" = true ]; then
  if [ -n "$old" ] && [ "$old" != "$cmd" ]; then
    printf '#!/bin/sh\n# The status line Claude Code ran before deskdash'"'"'s; scripts/install-claude-statusline.sh --remove restores it.\nexec %s\n' "$old" > "$next"
    chmod +x "$next"
    echo "Kept your status line: it now runs after deskdash's ($next)"
  fi
  printf '%s' "$current" | "$jq" --arg cmd "$cmd" '.statusLine = {type: "command", command: $cmd, padding: 0}' > "$file.tmp"
  mv "$file.tmp" "$file"
  echo "Claude Code's status line now runs $cmd"
  echo "The limits page fills in after Claude Code's next reply (Pro and Max plans only)."
else
  if [ -f "$next" ]; then
    prev=$(sed -n 's/^exec //p' "$next")
    printf '%s' "$current" | "$jq" --arg cmd "$prev" '.statusLine = {type: "command", command: $cmd}' > "$file.tmp"
    rm -f "$next"
    echo "Restored your status line: $prev"
  else
    printf '%s' "$current" | "$jq" --arg cmd "$cmd" 'if .statusLine.command == $cmd then del(.statusLine) else . end' > "$file.tmp"
    echo "Removed deskdash's status line from $file"
  fi
  mv "$file.tmp" "$file"
fi
