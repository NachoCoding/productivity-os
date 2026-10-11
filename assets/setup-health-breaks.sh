#!/bin/bash
# install | update: stage → verify → quit → unload → swap → plist → register → load. Never swaps while the old
# copy runs. Exit 0 = done, 75 = busy (Health Breaks would not quit, or another setup runs; nothing changed).
set -euo pipefail
umask 077
health_action="${1:-install}"
health_label=com.productivity-os.health-breaks
health_source="$(cd "$(dirname "$0")" && pwd)/Health Breaks.app"
health_target="$HOME/Applications/Health Breaks.app"
health_plist="$HOME/Library/LaunchAgents/$health_label.plist"
health_lock="$HOME/Applications/.health-breaks.setup.lock"
health_domain="gui/$(id -u)"
# Tool overrides exist for tests with a temporary HOME.
launchctl="${POS_LAUNCHCTL:-/bin/launchctl}" osascript="${POS_OSASCRIPT:-/usr/bin/osascript}"
pgrep="${POS_PGREP:-/usr/bin/pgrep}" ditto="${POS_DITTO:-/usr/bin/ditto}" codesign="${POS_CODESIGN:-/usr/bin/codesign}"
plutil="${POS_PLUTIL:-/usr/bin/plutil}"
open="${POS_OPEN:-/usr/bin/open}"
lsregister="${POS_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
quit_wait="${POS_QUIT_WAIT:-5}"
[[ "$quit_wait" =~ ^[0-9]+$ ]] || quit_wait=5
[[ "$health_action" =~ ^(install|update|uninstall)$ ]] || { echo 'Usage: setup-health-breaks.sh install|update|uninstall' >&2; exit 64; }
for health_path in "$HOME/Applications" "$health_target" "$HOME/Library/LaunchAgents" "$health_plist"; do
  [[ ! -L "$health_path" ]] || { echo 'Refusing a symbolic-link installation target.' >&2; exit 1; }
done
[[ "$health_action" == uninstall || -x "$health_source/Contents/MacOS/HealthBreaks" ]] || { echo 'Build Health Breaks first.' >&2; exit 1; }
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"

health_stage='' health_locked=''
health_cleanup() {
  # An interrupted swap puts the previous copy back.
  if [[ -n "$health_stage" && -e "$health_stage/previous.app" && ! -e "$health_target" ]]; then
    mv "$health_stage/previous.app" "$health_target" || true
  fi
  [[ -z "$health_stage" ]] || rm -rf "$health_stage"
  [[ -z "$health_locked" ]] || rm -rf "$health_lock"
}
health_signals() { trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM; }
trap health_cleanup EXIT
health_signals
# One setup at a time. A lock whose holder is gone (or older than any run) is stale.
health_take_lock() {
  local holder modified
  for _ in 1 2 3; do
    if mkdir "$health_lock" 2>/dev/null; then
      health_locked=1
      echo "$$" >"$health_lock/pid"
      return 0
    fi
    modified="$(stat -f %m "$health_lock" 2>/dev/null)" || continue
    holder="$(cat "$health_lock/pid" 2>/dev/null || true)"
    if (($(date +%s) - modified < 600)); then
      if [[ "$holder" =~ ^[0-9]+$ ]]; then
        if kill -0 "$holder" 2>/dev/null; then return 1; fi
      elif (($(date +%s) - modified < 10)); then
        return 1 # The holder is still writing its pid.
      fi
    fi
    if mv "$health_lock" "$health_lock.stale.$$" 2>/dev/null; then rm -rf "$health_lock.stale.$$"; fi
  done
  return 1
}
health_running() { "$pgrep" -f "^$health_target/Contents/MacOS/HealthBreaks" >/dev/null; }
# Builds that advertise the launcher protocol quit through their own URL, which needs no Automation consent;
# older builds get a normal AppleScript Quit.
health_quittable() {
  [[ "$("$plutil" -extract POSLauncherProtocol raw -o - "$health_target/Contents/Info.plist" 2>/dev/null)" =~ ^[1-9][0-9]*$ ]]
}
# Asks a running copy to quit and waits for it; fails if it is still running. The request runs alongside the
# wait so a quit stuck behind a dialog costs no more than the wait.
health_quit() {
  health_running || return 0
  if health_quittable; then
    "$open" -g -a "$health_target" 'pos-health://quit-if-idle' >/dev/null 2>&1 &
  else
    "$osascript" -e 'with timeout of 5 seconds' \
      -e "if application id \"$health_label\" is running then tell application id \"$health_label\" to quit" \
      -e 'end timeout' >/dev/null 2>&1 &
  fi
  local asker=$!
  for ((health_poll = 0; health_poll < quit_wait * 5; health_poll++)); do
    health_running || break
    sleep 0.2
  done
  kill "$asker" 2>/dev/null || true
  wait "$asker" 2>/dev/null || true
  ! health_running
}
health_requirement() { "$codesign" -d -r- "$1" 2>/dev/null | sed -n 's/^# *//; s/^designated => //p' || true; }
health_write_plist() {
  local plist="$health_stage/login.plist"
  "$plutil" -create xml1 "$plist"
  "$plutil" -insert Label -string "$health_label" "$plist"
  "$plutil" -insert ProgramArguments -json '[]' "$plist"
  "$plutil" -insert ProgramArguments.0 -string "$health_target/Contents/MacOS/HealthBreaks" "$plist"
  "$plutil" -insert ProgramArguments.1 -string --background "$plist"
  "$plutil" -insert RunAtLoad -bool YES "$plist"
  "$plutil" -insert KeepAlive -json '{"SuccessfulExit":false}' "$plist"
  "$plutil" -insert ProcessType -string Interactive "$plist"
  "$plutil" -insert ThrottleInterval -integer 30 "$plist"
  "$plutil" -insert LimitLoadToSessionType -string Aqua "$plist"
  mv "$plist" "$health_plist"
}

health_take_lock || { echo 'Another Health Breaks setup is running; try again shortly.' >&2; exit 75; }
if [[ "$health_action" == uninstall ]]; then
  health_quit || { echo 'Health Breaks did not quit, so it was not removed. Quit it from its menu bar, then retry.' >&2; exit 75; }
  "$launchctl" bootout "$health_domain/$health_label" 2>/dev/null || true
  rm -f "$health_plist"
  rm -rf "$health_target"
  echo 'Health Breaks removed. Your reminder preferences were preserved.'
  exit 0
fi
health_stage="$(mktemp -d "$HOME/Applications/.health-breaks.XXXXXX")"
"$ditto" "$health_source" "$health_stage/Health Breaks.app"
"$codesign" --verify --deep --strict "$health_stage/Health Breaks.app" ||
  { echo 'The bundled Health Breaks failed signature verification; rebuild it.' >&2; exit 1; }
if [[ -e "$health_target" && "$(health_requirement "$health_target")" != "$(health_requirement "$health_stage/Health Breaks.app")" ]]; then
  echo 'Warning: this Health Breaks build is signed differently, so macOS will ask for Camera access again.' >&2
fi
health_quit || { echo 'Health Breaks did not quit, so nothing was changed. Quit it from its menu bar to finish updating.' >&2; exit 75; }
# Unload, swap and plist must not stop halfway.
trap '' HUP INT TERM
"$launchctl" bootout "$health_domain/$health_label" 2>/dev/null || true
if [[ -e "$health_target" ]]; then mv "$health_target" "$health_stage/previous.app"; fi
if ! mv "$health_stage/Health Breaks.app" "$health_target"; then
  [[ ! -e "$health_stage/previous.app" ]] || mv "$health_stage/previous.app" "$health_target"
  exit 1
fi
# Reminders start at login on first install; updates keep the user's choice and refresh the agent definition.
if [[ -e "$health_plist" || ! -e "$health_stage/previous.app" ]]; then health_write_plist; fi
health_signals
"$lsregister" -f "$health_target" || echo 'Warning: Launch Services did not register Health Breaks.' >&2
if [[ -e "$health_plist" ]]; then
  "$launchctl" bootstrap "$health_domain" "$health_plist" 2>/dev/null ||
    "$launchctl" kickstart "$health_domain/$health_label" 2>/dev/null ||
    echo 'Warning: launchd did not start Health Breaks (Login Items may be off); Raycast opens it on demand.' >&2
fi
if [[ "$health_action" == update ]]; then echo "Updated $health_target"; else echo "Installed $health_target"; fi
