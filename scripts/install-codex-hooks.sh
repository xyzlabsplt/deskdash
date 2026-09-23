#!/bin/sh
# Adds deskdash's agent-status hook to Codex's user hooks (~/.codex/hooks.json); --remove takes it out.
# Idempotent, and backs the file up first. Codex runs a new hook only after you trust it: start codex, type /hooks.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
cmd="$here/hooks/agent-status.sh codex"
file=${CODEX_HOME:-$HOME/.codex}/hooks.json
jq=$(command -v jq || echo /usr/bin/jq)
events='["SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","PermissionRequest","Stop","Interrupt","SessionEnd"]'

add=true
case ${1:-} in
  "") ;;
  --remove) add=false ;;
  *) echo "usage: $0 [--remove]" >&2; exit 2 ;;
esac

mkdir -p "$(dirname "$file")"
current='{}'
if [ -f "$file" ]; then
  cp "$file" "$file.bak.$(date +%Y%m%d%H%M%S)"
  current=$(cat "$file")
fi

printf '%s' "$current" | "$jq" --arg cmd "$cmd" --argjson events "$events" --argjson add "$add" '
  .hooks = (.hooks // {})
  | reduce $events[] as $e (.;
      .hooks[$e] = ([(.hooks[$e] // [])[] | select(any(.hooks[]?; .command == $cmd) | not)]
                    + (if $add then [{hooks: [{type: "command", command: $cmd, timeout: 5}]}] else [] end))
      | if .hooks[$e] == [] then del(.hooks[$e]) else . end)
' > "$file.tmp"
mv "$file.tmp" "$file"

if [ "$add" = true ]; then
  echo "Added the deskdash hook to $file for: $(echo "$events" | tr -d '[]"' | tr ',' ' ')"
  echo "Codex runs it only after you trust it: start codex and run /hooks."
else
  echo "Removed the deskdash hook from $file"
fi
