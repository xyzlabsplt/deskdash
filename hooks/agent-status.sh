#!/bin/sh
# agent-status.sh: a coding agent's lifecycle hook that tells deskdash what the session is doing.
#
# Codex runs it from ~/.codex/hooks.json (scripts/install-codex-hooks.sh adds the entries):
#     "command": "/path/to/deskdash/hooks/agent-status.sh codex"
# Claude Code needs no hook (deskdash reads its session registry), but the same script works from
# ~/.claude/settings.json as "agent-status.sh claude" if that registry ever changes shape.
#
# Reads the hook JSON on stdin and writes one small file per session,
# ${DESKDASH_STATE_DIR:-~/.local/state/deskdash/agents}/<agent>-<session_id>.json, which the dashboard polls.
# Prints nothing and always exits 0, so it can never block, deny, or change what the agent does.
# Runs synchronously so events land in order; costs ~10 ms (two jq calls), plus one ps walk per session.
# Needs jq (/usr/bin/jq ships with macOS 15 and later).

exec 2>/dev/null
agent=${1:-codex}
dir=${DESKDASH_STATE_DIR:-$HOME/.local/state/deskdash/agents}
jq=$(command -v jq || echo /usr/bin/jq)
us=$(printf '\037')

input=$(cat) || exit 0
IFS=$us read -r event sid tool note <<EOF
$(printf '%s' "$input" | "$jq" -r '[.hook_event_name, .session_id, .tool_name, .notification_type]
  | map(. // "" | tostring) | join("\u001f")')
EOF
[ -n "$event" ] && [ -n "$sid" ] || exit 0
case $sid in *[!A-Za-z0-9._-]*) exit 0 ;; esac  # the id becomes a file name
file=$dir/$agent-$sid.json

waiting= detail=
case $event in
  SessionEnd) rm -f "$file"; exit 0 ;;
  SessionStart|Stop|StopFailure|Interrupt) status=idle ;;
  UserPromptSubmit|PostToolUse|PostToolUseFailure|SubagentStart|SubagentStop|PreCompact|PostCompact) status=busy ;;
  PreToolUse)
    case $tool in
      AskUserQuestion|ExitPlanMode|request_user_input) status=waiting waiting="input needed" ;;
      *) status=busy detail=$tool ;;
    esac ;;
  PermissionRequest) status=waiting waiting="permission prompt" ;;
  Notification)
    case $note in
      permission_prompt) status=waiting waiting="permission prompt" ;;
      elicitation_dialog|agent_needs_input) status=waiting waiting="input needed" ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac

prev=
[ -f "$file" ] && read -r prev < "$file"

# The agent's pid lets deskdash drop sessions that die without a SessionEnd. Look it up once per session
# (a new session, or a resumed one) by walking up from this hook to the first ancestor named after the agent.
pid=keep
if [ "$event" = SessionStart ] || [ -z "$prev" ]; then
  pid=$(ps -axo pid=,ppid=,comm= | awk -v start="$PPID" -v want="$agent" '
    { p = $1; pp = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); n = $0; sub(/.*\//, "", n); parent[p] = pp; name[p] = n }
    END { p = start; for (i = 0; i < 12 && p > 1; i++) { if (index(name[p], want) == 1) { print p; exit } p = parent[p] }
          print 0 }')
fi

[ -d "$dir" ] || mkdir -p "$dir" || exit 0
out=$(printf '%s' "$input" | "$jq" -c --arg agent "$agent" --arg status "$status" --arg waiting "$waiting" \
  --arg detail "$detail" --arg event "$event" --arg pid "$pid" --arg prev "$prev" '
  (now * 1000 | floor) as $now
  | ($prev | try fromjson catch {} | if type == "object" then . else {} end) as $p
  | (if $pid == "keep" then ($p.pid // 0) else ($pid | tonumber? // 0) end) as $pid
  | {
      agent: $agent,
      sessionId: .session_id,
      pid: $pid,
      cwd: (.cwd // $p.cwd),
      name: ($p.name // ((.prompt // .user_prompt // "") | tostring | split("\n")[0] | .[0:60]
                         | if . == "" then null else . end)),
      status: $status,
      waitingFor: (if $waiting == "" then null else $waiting end),
      detail: (if $detail != "" then $detail elif $status == "busy" then $p.detail else null end),
      event: $event,
      startedAt: (if $p.pid == $pid then ($p.startedAt // $now) else $now end),
      updatedAt: $now,
      statusUpdatedAt: (if $p.status == $status then ($p.statusUpdatedAt // $now) else $now end)
    }') && printf '%s\n' "$out" > "$file"
exit 0
