#!/bin/sh
# claude-usage.sh: hands deskdash the plan limits the Claude desktop app reports, for Claude Code used in the app, which
# runs no status line. The app's usage card (its get_usage tool, which a Claude session in the app can call) gives
# each window's percentUsed and resetsAt; pipe its JSON in, whole or just its "plan" object:
#     hooks/claude-usage.sh <<'EOF'
#     {"plan": {"status": "ok", "plan": "Max", "windows": [{"label": "5-hour limit", "percentUsed": 8, ...}, ...]}}
#     EOF
# It writes ${DESKDASH_LIMITS_DIR:-~/.local/state/deskdash/limits}/claude.json in the status line's shape, so the
# limits page reads both alike, and prints what it wrote. Windows are told apart by label: "5-hour", and the weekly
# one for all models. Needs jq (/usr/bin/jq ships with macOS 15 and later).

dir=${DESKDASH_LIMITS_DIR:-$HOME/.local/state/deskdash/limits}
jq=$(command -v jq || echo /usr/bin/jq)
mkdir -p "$dir" || exit 1

"$jq" -c --argjson now "$(date +%s)" '
  (.plan // .) as $p
  | select($p.status == "ok")
  | ($p.windows // []) as $w
  | ($w | map(select(.label | test("5-hour"; "i"))) | first) as $five
  | ($w | map(select(.label | test("weekly"; "i")) | select(.label | test("all models"; "i"))) | first
     // ($w | map(select(.label | test("weekly"; "i"))) | first)) as $week
  | {updatedAt: ($now * 1000), source: "claude-desktop", plan: ($p.plan // null | if . then ascii_downcase else . end),
     rate_limits: ({}
       + (if $five then {five_hour: {used_percentage: $five.percentUsed, resets_at: $five.resetsAt}} else {} end)
       + (if $week then {seven_day: {used_percentage: $week.percentUsed, resets_at: $week.resetsAt}} else {} end))}
  | select(.rate_limits | length > 0)' > "$dir/claude.json.tmp" \
  && [ -s "$dir/claude.json.tmp" ] && mv -f "$dir/claude.json.tmp" "$dir/claude.json" && cat "$dir/claude.json" \
  || { rm -f "$dir/claude.json.tmp"; echo "claude-usage.sh: no plan limits in that JSON" >&2; exit 1; }
