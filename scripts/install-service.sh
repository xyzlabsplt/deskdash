#!/bin/sh
# Runs deskdash at login: installs the LaunchAgent local.deskdash (in ~/Library/LaunchAgents), which launchd restarts
# if it exits, and starts it now. Build first with scripts/build.sh.
#
#   scripts/install-service.sh            install (or reinstall) and start; also starts it again after Quit
#   scripts/install-service.sh --remove   stop it and take it out
#   scripts/install-service.sh --print    show the LaunchAgent it would install, and change nothing
#
# After a later build, restart it with: launchctl kickstart -k gui/$(id -u)/local.deskdash
# Quit in deskdash's menu stops the agent until the next login. Its log is ~/Library/Logs/deskdash.log.
set -eu
cd "$(dirname "$0")/.."

label=local.deskdash
plist=$HOME/Library/LaunchAgents/$label.plist
domain=gui/$(id -u)
program=$PWD/deskdash.app/Contents/MacOS/deskdash
logfile=$HOME/Library/Logs/deskdash.log

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# The app bundle's executable, never .build/release/deskdash: macOS keeps the Local Network permission (which the
# purifier needs) for an app bundle across rebuilds, but not for a bare binary.
agent() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$(xml "$program")</string></array>
  <key>WorkingDirectory</key><string>$(xml "$PWD")</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$(xml "$logfile")</string>
  <key>StandardErrorPath</key><string>$(xml "$logfile")</string>
</dict>
</plist>
EOF
}

unload() {
  launchctl bootout "$domain/$label" 2>/dev/null || return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do  # bootout returns before the job is gone
    launchctl print "$domain/$label" >/dev/null 2>&1 || return 0
    sleep 0.5
  done
}

case ${1:-} in
  "") ;;
  --print) agent; exit 0 ;;
  --remove)
    unload
    rm -f "$plist"
    echo "Removed $label: deskdash no longer starts at login."
    exit 0 ;;
  *) echo "usage: $0 [--remove | --print]" >&2; exit 2 ;;
esac

[ -x "$program" ] || { echo "No $program yet: run scripts/build.sh first." >&2; exit 1; }
# Another LaunchAgent that runs deskdash would put a second dashboard on the same screen.
other=$(launchctl list | awk -v me="$label" '$3 ~ /deskdash/ && $3 != me && $3 !~ /^application\./ { print $3 }')
if [ -n "$other" ]; then
  echo "deskdash already runs as the launchd job $other. Remove that first, or two dashboards share the screen." >&2
  exit 1
fi

mkdir -p "$(dirname "$plist")" "$(dirname "$logfile")"
agent > "$plist.new"
plutil -lint -s "$plist.new"
mv "$plist.new" "$plist"
unload
launchctl bootstrap "$domain" "$plist"
echo "Installed $label: deskdash runs now and at every login. Its log: $logfile"
