#!/bin/bash
# install | update: stage → verify → quit → unload → swap → plist → register → load. Never swaps while the old
# copy runs. Exit 0 = done, 75 = busy (Clipboard History would not quit, or another setup runs; nothing changed).
set -euo pipefail
umask 077
clip_action="${1:-install}"
clip_label=com.productivity-os.clipboard-history
clip_source="$(cd "$(dirname "$0")" && pwd)/Clipboard History.app"
clip_target="$HOME/Applications/Clipboard History.app"
clip_plist="$HOME/Library/LaunchAgents/$clip_label.plist"
clip_lock="$HOME/Applications/.clipboard-history.setup.lock"
clip_domain="gui/$(id -u)"
# Tool overrides exist for tests with a temporary HOME.
launchctl="${POS_LAUNCHCTL:-/bin/launchctl}" osascript="${POS_OSASCRIPT:-/usr/bin/osascript}"
pgrep="${POS_PGREP:-/usr/bin/pgrep}" ditto="${POS_DITTO:-/usr/bin/ditto}" codesign="${POS_CODESIGN:-/usr/bin/codesign}"
plutil="${POS_PLUTIL:-/usr/bin/plutil}"
open="${POS_OPEN:-/usr/bin/open}"
lsregister="${POS_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
quit_wait="${POS_QUIT_WAIT:-5}"
[[ "$quit_wait" =~ ^[0-9]+$ ]] || quit_wait=5
[[ "$clip_action" =~ ^(install|update|uninstall)$ ]] || { echo 'Usage: setup-clipboard-history.sh install|update|uninstall' >&2; exit 64; }
for clip_path in "$HOME/Applications" "$clip_target" "$HOME/Library/LaunchAgents" "$clip_plist"; do
  [[ ! -L "$clip_path" ]] || { echo 'Refusing a symbolic-link installation target.' >&2; exit 1; }
done
[[ "$clip_action" == uninstall || -x "$clip_source/Contents/MacOS/ClipboardHistory" ]] || { echo 'Build Clipboard History first.' >&2; exit 1; }
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"

clip_stage='' clip_locked=''
clip_cleanup() {
  # An interrupted swap puts the previous copy back.
  if [[ -n "$clip_stage" && -e "$clip_stage/previous.app" && ! -e "$clip_target" ]]; then
    mv "$clip_stage/previous.app" "$clip_target" || true
  fi
  [[ -z "$clip_stage" ]] || rm -rf "$clip_stage"
  [[ -z "$clip_locked" ]] || rm -rf "$clip_lock"
}
clip_signals() { trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM; }
trap clip_cleanup EXIT
clip_signals
# One setup at a time. A lock whose holder is gone (or older than any run) is stale.
clip_take_lock() {
  local holder modified
  for _ in 1 2 3; do
    if mkdir "$clip_lock" 2>/dev/null; then
      clip_locked=1
      echo "$$" >"$clip_lock/pid"
      return 0
    fi
    modified="$(stat -f %m "$clip_lock" 2>/dev/null)" || continue
    holder="$(cat "$clip_lock/pid" 2>/dev/null || true)"
    if (($(date +%s) - modified < 600)); then
      if [[ "$holder" =~ ^[0-9]+$ ]]; then
        if kill -0 "$holder" 2>/dev/null; then return 1; fi
      elif (($(date +%s) - modified < 10)); then
        return 1 # The holder is still writing its pid.
      fi
    fi
    if mv "$clip_lock" "$clip_lock.stale.$$" 2>/dev/null; then rm -rf "$clip_lock.stale.$$"; fi
  done
  return 1
}
clip_running() { "$pgrep" -f "^$clip_target/Contents/MacOS/ClipboardHistory" >/dev/null; }
# Builds that advertise the launcher protocol quit through their own URL, which needs no Automation consent;
# older builds get a normal AppleScript Quit.
clip_quittable() {
  [[ "$("$plutil" -extract POSLauncherProtocol raw -o - "$clip_target/Contents/Info.plist" 2>/dev/null)" =~ ^[1-9][0-9]*$ ]]
}
# Asks a running copy to quit and waits for it; fails if it is still running. The request runs alongside the
# wait so a quit stuck behind a dialog costs no more than the wait.
clip_quit() {
  clip_running || return 0
  if clip_quittable; then
    "$open" -g -a "$clip_target" 'pos-clipboard://quit-if-idle' >/dev/null 2>&1 &
  else
    "$osascript" -e 'with timeout of 5 seconds' \
      -e "if application id \"$clip_label\" is running then tell application id \"$clip_label\" to quit" \
      -e 'end timeout' >/dev/null 2>&1 &
  fi
  local asker=$!
  for ((clip_poll = 0; clip_poll < quit_wait * 5; clip_poll++)); do
    clip_running || break
    sleep 0.2
  done
  kill "$asker" 2>/dev/null || true
  wait "$asker" 2>/dev/null || true
  ! clip_running
}
clip_requirement() { "$codesign" -d -r- "$1" 2>/dev/null | sed -n 's/^# *//; s/^designated => //p' || true; }
clip_write_plist() {
  local plist="$clip_stage/login.plist"
  "$plutil" -create xml1 "$plist"
  "$plutil" -insert Label -string "$clip_label" "$plist"
  "$plutil" -insert ProgramArguments -json '[]' "$plist"
  "$plutil" -insert ProgramArguments.0 -string "$clip_target/Contents/MacOS/ClipboardHistory" "$plist"
  "$plutil" -insert ProgramArguments.1 -string --background "$plist"
  "$plutil" -insert RunAtLoad -bool YES "$plist"
  "$plutil" -insert KeepAlive -json '{"SuccessfulExit":false}' "$plist"
  "$plutil" -insert ProcessType -string Interactive "$plist"
  "$plutil" -insert ThrottleInterval -integer 30 "$plist"
  "$plutil" -insert LimitLoadToSessionType -string Aqua "$plist"
  mv "$plist" "$clip_plist"
}

clip_take_lock || { echo 'Another Clipboard History setup is running; try again shortly.' >&2; exit 75; }
if [[ "$clip_action" == uninstall ]]; then
  clip_quit || { echo 'Clipboard History did not quit, so it was not removed. Quit it from its menu bar, then retry.' >&2; exit 75; }
  "$launchctl" bootout "$clip_domain/$clip_label" 2>/dev/null || true
  rm -f "$clip_plist"
  rm -rf "$clip_target"
  echo 'Clipboard History removed. Encrypted history and its Keychain key were preserved.'
  exit 0
fi
clip_stage="$(mktemp -d "$HOME/Applications/.clipboard-history.XXXXXX")"
"$ditto" "$clip_source" "$clip_stage/Clipboard History.app"
"$codesign" --verify --deep --strict "$clip_stage/Clipboard History.app" ||
  { echo 'The bundled Clipboard History failed signature verification; rebuild it.' >&2; exit 1; }
if [[ -e "$clip_target" && "$(clip_requirement "$clip_target")" != "$(clip_requirement "$clip_stage/Clipboard History.app")" ]]; then
  echo 'Warning: this Clipboard History build is signed differently, so macOS will ask again for Accessibility access and for its Keychain key.' >&2
fi
clip_quit || { echo 'Clipboard History did not quit, so nothing was changed. Quit it from its menu bar to finish updating.' >&2; exit 75; }
# Unload, swap and plist must not stop halfway.
trap '' HUP INT TERM
"$launchctl" bootout "$clip_domain/$clip_label" 2>/dev/null || true
if [[ -e "$clip_target" ]]; then mv "$clip_target" "$clip_stage/previous.app"; fi
if ! mv "$clip_stage/Clipboard History.app" "$clip_target"; then
  [[ ! -e "$clip_stage/previous.app" ]] || mv "$clip_stage/previous.app" "$clip_target"
  exit 1
fi
# Login startup is on after a first install; updates keep the user's choice and refresh the agent definition.
if [[ -e "$clip_plist" || ! -e "$clip_stage/previous.app" ]]; then clip_write_plist; fi
clip_signals
"$lsregister" -f "$clip_target" || echo 'Warning: Launch Services did not register Clipboard History.' >&2
if [[ -e "$clip_plist" ]]; then
  "$launchctl" bootstrap "$clip_domain" "$clip_plist" 2>/dev/null ||
    "$launchctl" kickstart "$clip_domain/$clip_label" 2>/dev/null ||
    echo 'Warning: launchd did not start Clipboard History (Login Items may be off); Raycast opens it on demand.' >&2
fi
if [[ "$clip_action" == update ]]; then echo "Updated $clip_target"; else echo "Installed $clip_target"; fi
