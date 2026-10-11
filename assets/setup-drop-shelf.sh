#!/bin/bash
# install | update: stage → verify → quit if idle → unload → swap → plist → register → load. Never swaps while the
# old copy runs. Exit 0 = done, 75 = busy (Drop Shelf is in use or too old to ask, or another setup runs; nothing
# changed).
set -euo pipefail
umask 077
shelf_action="${1:-install}"
shelf_label=com.productivity-os.drop-shelf
shelf_source="$(cd "$(dirname "$0")" && pwd)/Drop Shelf.app"
shelf_target="$HOME/Applications/Drop Shelf.app"
shelf_plist="$HOME/Library/LaunchAgents/$shelf_label.plist"
shelf_lock="$HOME/Applications/.drop-shelf.setup.lock"
shelf_domain="gui/$(id -u)"
# Tool overrides exist for tests with a temporary HOME.
launchctl="${POS_LAUNCHCTL:-/bin/launchctl}" open="${POS_OPEN:-/usr/bin/open}"
pgrep="${POS_PGREP:-/usr/bin/pgrep}" ditto="${POS_DITTO:-/usr/bin/ditto}" codesign="${POS_CODESIGN:-/usr/bin/codesign}"
plutil="${POS_PLUTIL:-/usr/bin/plutil}"
lsregister="${POS_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
# quit-if-idle exits at once when idle and never when busy, so a long wait only delays Raycast.
quit_wait="${POS_QUIT_WAIT:-2}"
[[ "$quit_wait" =~ ^[0-9]+$ ]] || quit_wait=2
[[ "$shelf_action" =~ ^(install|update|uninstall)$ ]] || { echo 'Usage: setup-drop-shelf.sh install|update|uninstall' >&2; exit 64; }
for shelf_path in "$HOME/Applications" "$shelf_target" "$HOME/Library/LaunchAgents" "$shelf_plist"; do
  [[ ! -L "$shelf_path" ]] || { echo 'Refusing a symbolic-link installation target.' >&2; exit 1; }
done
[[ "$shelf_action" == uninstall || -x "$shelf_source/Contents/MacOS/DropShelf" ]] || { echo 'Build Drop Shelf first.' >&2; exit 1; }
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"

shelf_stage='' shelf_locked=''
shelf_cleanup() {
  # An interrupted swap puts the previous copy back.
  if [[ -n "$shelf_stage" && -e "$shelf_stage/previous.app" && ! -e "$shelf_target" ]]; then
    mv "$shelf_stage/previous.app" "$shelf_target" || true
  fi
  [[ -z "$shelf_stage" ]] || rm -rf "$shelf_stage"
  [[ -z "$shelf_locked" ]] || rm -rf "$shelf_lock"
}
shelf_signals() { trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM; }
trap shelf_cleanup EXIT
shelf_signals
# One setup at a time. A lock whose holder is gone (or older than any run) is stale.
shelf_take_lock() {
  local holder modified
  for _ in 1 2 3; do
    if mkdir "$shelf_lock" 2>/dev/null; then
      shelf_locked=1
      echo "$$" >"$shelf_lock/pid"
      return 0
    fi
    modified="$(stat -f %m "$shelf_lock" 2>/dev/null)" || continue
    holder="$(cat "$shelf_lock/pid" 2>/dev/null || true)"
    if (($(date +%s) - modified < 600)); then
      if [[ "$holder" =~ ^[0-9]+$ ]]; then
        if kill -0 "$holder" 2>/dev/null; then return 1; fi
      elif (($(date +%s) - modified < 10)); then
        return 1 # The holder is still writing its pid.
      fi
    fi
    if mv "$shelf_lock" "$shelf_lock.stale.$$" 2>/dev/null; then rm -rf "$shelf_lock.stale.$$"; fi
  done
  return 1
}
shelf_running() { "$pgrep" -f "^$shelf_target/Contents/MacOS/DropShelf" >/dev/null; }
# Only builds that advertise the launcher protocol understand quit-if-idle; older ones count as busy.
shelf_quittable() {
  [[ "$("$plutil" -extract POSLauncherProtocol raw -o - "$shelf_target/Contents/Info.plist" 2>/dev/null)" =~ ^[1-9][0-9]*$ ]]
}
shelf_busy() {
  if shelf_quittable; then
    echo "Drop Shelf is in use (open shelves or a file operation), so nothing was changed. Close its shelves to finish $1." >&2
  else
    echo "Drop Shelf is running a build that cannot be asked to quit, so nothing was changed. Quit it from its menu bar to finish $1." >&2
  fi
  exit 75
}
# Asks a running copy to quit if it is idle and waits for it; fails if it is still running.
shelf_quit() {
  shelf_running || return 0
  shelf_quittable || return 1
  "$open" -g -a "$shelf_target" 'pos-shelf://quit-if-idle' >/dev/null 2>&1 || true
  for ((shelf_poll = 0; shelf_poll < quit_wait * 5; shelf_poll++)); do
    shelf_running || return 0
    sleep 0.2
  done
  ! shelf_running
}
shelf_requirement() { "$codesign" -d -r- "$1" 2>/dev/null | sed -n 's/^# *//; s/^designated => //p' || true; }
shelf_write_plist() {
  local plist="$shelf_stage/login.plist"
  "$plutil" -create xml1 "$plist"
  "$plutil" -insert Label -string "$shelf_label" "$plist"
  "$plutil" -insert ProgramArguments -json '[]' "$plist"
  "$plutil" -insert ProgramArguments.0 -string "$shelf_target/Contents/MacOS/DropShelf" "$plist"
  "$plutil" -insert ProgramArguments.1 -string --background "$plist"
  "$plutil" -insert RunAtLoad -bool YES "$plist"
  "$plutil" -insert KeepAlive -json '{"SuccessfulExit":false}' "$plist"
  "$plutil" -insert ProcessType -string Interactive "$plist"
  "$plutil" -insert ThrottleInterval -integer 30 "$plist"
  "$plutil" -insert LimitLoadToSessionType -string Aqua "$plist"
  mv "$plist" "$shelf_plist"
}

shelf_take_lock || { echo 'Another Drop Shelf setup is running; try again shortly.' >&2; exit 75; }
if [[ "$shelf_action" == uninstall ]]; then
  shelf_quit || shelf_busy 'removing it'
  "$launchctl" bootout "$shelf_domain/$shelf_label" 2>/dev/null || true
  rm -f "$shelf_plist"
  rm -rf "$shelf_target"
  echo 'Drop Shelf removed. Shelf history and saved items were preserved.'
  exit 0
fi
# A running build that cannot be asked to quit makes staging pointless.
if shelf_running && ! shelf_quittable; then shelf_busy updating; fi
shelf_stage="$(mktemp -d "$HOME/Applications/.drop-shelf.XXXXXX")"
"$ditto" "$shelf_source" "$shelf_stage/Drop Shelf.app"
"$codesign" --verify --deep --strict "$shelf_stage/Drop Shelf.app" ||
  { echo 'The bundled Drop Shelf failed signature verification; rebuild it.' >&2; exit 1; }
if [[ -e "$shelf_target" && "$(shelf_requirement "$shelf_target")" != "$(shelf_requirement "$shelf_stage/Drop Shelf.app")" ]]; then
  echo 'Warning: this Drop Shelf build is signed differently, so macOS may ask for its permissions again.' >&2
fi
shelf_quit || shelf_busy updating
# Unload, swap and plist must not stop halfway.
trap '' HUP INT TERM
"$launchctl" bootout "$shelf_domain/$shelf_label" 2>/dev/null || true
if [[ -e "$shelf_target" ]]; then mv "$shelf_target" "$shelf_stage/previous.app"; fi
if ! mv "$shelf_stage/Drop Shelf.app" "$shelf_target"; then
  [[ ! -e "$shelf_stage/previous.app" ]] || mv "$shelf_stage/previous.app" "$shelf_target"
  exit 1
fi
# Login startup is opt-in from Drop Shelf Settings; an existing agent definition is refreshed.
if [[ -e "$shelf_plist" ]]; then shelf_write_plist; fi
shelf_signals
"$lsregister" -f "$shelf_target" || echo 'Warning: Launch Services did not register Drop Shelf.' >&2
if [[ -e "$shelf_plist" ]]; then
  "$launchctl" bootstrap "$shelf_domain" "$shelf_plist" 2>/dev/null ||
    "$launchctl" kickstart "$shelf_domain/$shelf_label" 2>/dev/null ||
    echo 'Warning: launchd did not start Drop Shelf (Login Items may be off); Raycast opens it on demand.' >&2
fi
if [[ "$shelf_action" == update ]]; then echo "Updated $shelf_target"; else echo "Installed $shelf_target"; fi
